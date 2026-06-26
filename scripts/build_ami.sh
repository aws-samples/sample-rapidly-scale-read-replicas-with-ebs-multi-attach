#!/usr/bin/env bash
# Launches a temporary EC2, installs RocksDB in two phases (with reboot between), bakes an AMI.
# Phase 1: Install packages — ends with explicit reboot to load new kernel modules
# Phase 2: Compile RocksDB + configure services (after reboot)
set -euo pipefail

# Safety net: always terminate the temporary build instance, even if this script is
# interrupted (Ctrl-C), errors out under `set -e`, or a wait/SSH loop dies. Without
# this, an interrupted build leaves an expensive c5.9xlarge running. On the normal
# success path the instance is already terminated below, so this trap is just a no-op
# (terminating an already-terminated instance is harmless).
cleanup_builder() {
    if [ -n "${INSTANCE_ID:-}" ]; then
        echo "==> (cleanup) terminating build instance ${INSTANCE_ID}..."
        aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_builder EXIT

SCRIPT_DIR="$(dirname "$0")"
KEY_NAME="rocksdb-key"
KEY_PATH="${SCRIPT_DIR}/${KEY_NAME}.pem"
AMI_ID_FILE="${SCRIPT_DIR}/../ami_id.txt"
REMOTE_USER="ubuntu"
# Use a bash array so each option is passed as a distinct argument (no word-splitting surprises).
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -i "${KEY_PATH}")

# ===== CREATE KEY PAIR (if not already present) =====
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_DEFAULT_REGION:-us-east-1}" > /dev/null 2>&1; then
    echo "==> Key pair '${KEY_NAME}' already exists in AWS."
    if [ ! -f "${KEY_PATH}" ]; then
        echo "    WARNING: ${KEY_PATH} not found locally — SSH will fail."
        echo "    Delete the key pair in AWS and re-run to regenerate."
        exit 1
    fi
else
    echo "==> Creating EC2 key pair '${KEY_NAME}'..."
    aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --query 'KeyMaterial' \
        --output text > "${KEY_PATH}"
    chmod 600 "${KEY_PATH}"
    echo "    Saved to ${KEY_PATH}"
fi

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=mapPublicIpOnLaunch,Values=true" \
    --query 'Subnets[0].SubnetId' --output text)
AMI_BASE=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

echo "==> Launching build instance (c5.9xlarge)..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_BASE}" \
    --instance-type c5.9xlarge \
    --key-name "${KEY_NAME}" \
    --subnet-id "${SUBNET_ID}" \
    --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rocksdb-ami-builder}]' \
    --query 'Instances[0].InstanceId' --output text)

echo "    Instance: ${INSTANCE_ID}"
echo "==> Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "    IP: ${PUBLIC_IP}"

echo "==> Waiting for SSH..."
until ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" "echo ready" 2>/dev/null; do
    sleep 5
done

echo "==> Uploading scripts..."
REMOTE_DIR="/home/${REMOTE_USER}/build"
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" "mkdir -p ${REMOTE_DIR}"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/setup_phase1.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/setup_phase1.sh"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/setup_phase2.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/setup_phase2.sh"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/rocksdb_service.cc" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/rocksdb_service.cc"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/cluster_watcher.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/cluster_watcher.sh"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/cluster_self_remove.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/cluster_self_remove.sh"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/cluster_key_sync.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/cluster_key_sync.sh"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/fence_aws_wrapper.sh" "${REMOTE_USER}@${PUBLIC_IP}:${REMOTE_DIR}/fence_aws_wrapper.sh"

# ===== PHASE 1: Install packages =====
echo "==> Phase 1: Installing packages (will reboot at end)..."
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" \
    "sudo chmod +x ${REMOTE_DIR}/setup_phase1.sh && sudo ${REMOTE_DIR}/setup_phase1.sh" 2>&1 || true

# Phase 1 ends with 'sudo reboot'. Wait for SSH to go down, then come back.
echo "==> Waiting for instance to reboot..."
# First, wait for SSH to become unreachable (reboot started)
for _i in $(seq 1 30); do
    if ! ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" "echo up" 2>/dev/null; then
        echo "    SSH is down (reboot in progress)."
        break
    fi
    sleep 5
done

# Now wait for SSH to come back (reboot complete)
echo "==> Waiting for SSH after reboot..."
sleep 15
until ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" "echo ready" 2>/dev/null; do
    sleep 10
done
echo "==> SSH is back. Reboot complete."

# ===== PHASE 2: Compile RocksDB =====
echo "==> Phase 2: Compiling RocksDB (detached via systemd-run)..."
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" \
    "sudo chmod +x ${REMOTE_DIR}/setup_phase2.sh && \
     sudo systemd-run --unit=rocksdb-build \
       bash -c '${REMOTE_DIR}/setup_phase2.sh > /tmp/build.log 2>&1; echo \$? > /tmp/build_exit_code'"

echo "==> Build running. Polling every 30s..."
while true; do
    sleep 30
    EXIT_CODE=$(ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" \
        "cat /tmp/build_exit_code 2>/dev/null" 2>/dev/null || echo "")
    COUNT=$(ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" \
        "grep -c 'Building CXX' /tmp/build.log 2>/dev/null || echo 0" 2>/dev/null || echo "?")
    LAST=$(ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" \
        "tail -1 /tmp/build.log 2>/dev/null" 2>/dev/null || echo "...")
    echo "    [$(date +%H:%M:%S)] files: ${COUNT} | ${LAST}"
    if [ "${EXIT_CODE}" = "0" ]; then
        echo "==> Build complete."
        break
    elif [ -n "${EXIT_CODE}" ]; then
        echo "==> Build failed (exit ${EXIT_CODE}). Last 30 lines:"
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${PUBLIC_IP}" "sudo tail -30 /tmp/build.log" 2>/dev/null || true
        aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" > /dev/null
        exit 1
    fi
done

# ===== CREATE AMI =====
echo "==> Stopping instance for AMI creation..."
aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" > /dev/null
aws ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}"

echo "==> Creating AMI..."
AMI_NAME="rocksdb-9.7.4-ubuntu2404-$(date +%Y%m%d%H%M%S)"
NEW_AMI_ID=$(aws ec2 create-image \
    --instance-id "${INSTANCE_ID}" \
    --name "${AMI_NAME}" \
    --description "Ubuntu 24.04 with RocksDB 9.7.4 + GFS2 stack" \
    --no-reboot \
    --query 'ImageId' --output text)

echo "    AMI ID: ${NEW_AMI_ID}"
echo "==> Waiting for AMI to be available..."
aws ec2 wait image-available --image-ids "${NEW_AMI_ID}"

echo "==> Terminating build instance..."
aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" > /dev/null

echo "${NEW_AMI_ID}" > "${AMI_ID_FILE}"
echo "==> AMI ready: ${NEW_AMI_ID} (saved to ami_id.txt)"
