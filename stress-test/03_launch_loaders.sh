#!/usr/bin/env bash
# Launch a fleet of load generator EC2 instances to bombard the ALB.
# Loaders are fully self-contained — they auto-start via UserData, no SSH needed.
#
# Usage: ./03_launch_loaders.sh [--count 60] [--instance-type c5.4xlarge]
#                               [--duration 1800] [--concurrency 1000] [--keys 2000000000]
set -euo pipefail
STRESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${STRESS_DIR}/../test/common.sh"

COUNT=20
INSTANCE_TYPE="c5.4xlarge"
DURATION=1800
CONCURRENCY=1000
NUM_KEYS=2000000000

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)         COUNT="$2";         shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --duration)      DURATION="$2";      shift 2 ;;
        --concurrency)   CONCURRENCY="$2";   shift 2 ;;
        --keys)          NUM_KEYS="$2";      shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

ALB_DNS=$(get_alb_dns)
[ -z "${ALB_DNS}" ] && echo "ERROR: No ALB found" && exit 1

# vCPU-quota guard (mirrors the TUI). Assumes 16 vCPU per loader (c5.4xlarge).
VCPUS=$(( COUNT * 16 ))
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47 \
    --query 'Quota.Value' --output text --region "${REGION}" 2>/dev/null || echo "")
if [ -n "${QUOTA}" ] && [ "${QUOTA}" != "None" ]; then
    QUOTA_INT=$(python3 -c "print(int(float('${QUOTA}')))")
    if [ "${VCPUS}" -gt "${QUOTA_INT}" ]; then
        echo "ERROR: ${COUNT} × ${INSTANCE_TYPE} ≈ ${VCPUS} vCPUs exceeds your On-Demand vCPU quota (${QUOTA_INT})."
        echo "       Use --count <= $(( QUOTA_INT / 16 ))."
        exit 1
    fi
fi

VPC_ID=$(get_vpc_id)
if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text --region "${REGION}")
fi
SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=mapPublicIpOnLaunch,Values=true" \
    --query 'Subnets[?AvailabilityZone!=`us-east-1a`].SubnetId' \
    --output text --region "${REGION}" | awk '{print $1}')

# Create (or reuse) loader security group
LOADER_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=rocksdb-loader-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "${REGION}" 2>/dev/null || echo "")
if [ -z "${LOADER_SG}" ] || [ "${LOADER_SG}" = "None" ]; then
    LOADER_SG=$(aws ec2 create-security-group \
        --group-name "rocksdb-loader-sg" \
        --description "RocksDB load generator - all outbound" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text --region "${REGION}")
    aws ec2 authorize-security-group-egress \
        --group-id "${LOADER_SG}" \
        --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
        --region "${REGION}" 2>/dev/null || true
    echo "Created loader SG: ${LOADER_SG}"
else
    echo "Reusing loader SG: ${LOADER_SG}"
fi

AMI_BASE=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "${REGION}")

USERDATA_FILE=$(mktemp /tmp/loader_userdata.XXXXXX)
cat > "${USERDATA_FILE}" << EOF
#!/bin/bash
exec > /var/log/loader-setup.log 2>&1
set -uo pipefail

# Prevent the stock-AMI first-boot reboot (unattended-upgrades installs a newer
# kernel and auto-reboots ~2-3 min in, killing wrk mid-run). Block it before wrk.
systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl mask unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask reboot.target 2>/dev/null || true

# Wait for first-boot apt to release the dpkg lock (held by unattended-upgrades /
# apt-daily). NOTE: do NOT use `cloud-init status --wait` here — this script IS run by
# cloud-init, so waiting on cloud-init would deadlock. The dpkg-lock loop is safe.
for _i in \$(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 5
done
apt-get purge -y -q unattended-upgrades 2>/dev/null || true

# Install wrk with retries (lock contention / transient mirror errors are common on
# first boot). Don't proceed until wrk is actually present.
for _i in \$(seq 1 30); do
    apt-get update -q && apt-get install -y -q wrk && command -v wrk >/dev/null 2>&1 && break
    echo "  wrk install attempt \${_i} failed; retrying in 10s..."
    sleep 10
done
if ! command -v wrk >/dev/null 2>&1; then
    echo "FATAL: wrk failed to install after retries" ; exit 1
fi

# Lua: random key per request, URL-encode the colon
cat > /tmp/random_keys.lua << 'LUA'
math.randomseed(os.time() + math.random(1000000))
local num_keys = ${NUM_KEYS}
function request()
    local key = string.format("stress%%3A%016d", math.random(0, num_keys - 1))
    return wrk.format("GET", "/get?key=" .. key)
end
LUA

echo "Starting load: ALB=${ALB_DNS} duration=${DURATION}s concurrency=${CONCURRENCY}"

# 16 threads matches c5.4xlarge vCPU count for maximum throughput
wrk -t16 -c${CONCURRENCY} -d${DURATION}s \
    --script /tmp/random_keys.lua \
    --latency \
    "http://${ALB_DNS}" \
    > /tmp/load_results.txt 2>&1 || true

echo "Load test complete" >> /tmp/load_results.txt
cat /tmp/load_results.txt
EOF

USERDATA_B64=$(base64 < "${USERDATA_FILE}")
rm -f "${USERDATA_FILE}"

echo "Launching ${COUNT} load generator instances (${INSTANCE_TYPE} on-demand)..."
INSTANCE_IDS=$(aws ec2 run-instances \
    --image-id "${AMI_BASE}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${LOADER_SG}" \
    --associate-public-ip-address \
    --count "${COUNT}" \
    --user-data "${USERDATA_B64}" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rocksdb-loader}]' \
    --query 'Instances[].InstanceId' \
    --output text --region "${REGION}")

echo "Launched: ${INSTANCE_IDS}"
read -ra _IDS <<< "${INSTANCE_IDS}"
aws ec2 wait instance-running --instance-ids "${_IDS[@]}" --region "${REGION}"
echo "${INSTANCE_IDS}" > /tmp/loader_instance_ids.txt

echo "Saved to /tmp/loader_instance_ids.txt"
echo "Loaders auto-start (~60s for wrk install). Run 04_run_stress.sh to monitor."
