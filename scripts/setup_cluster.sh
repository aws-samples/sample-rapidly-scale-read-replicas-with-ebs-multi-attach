#!/usr/bin/env bash
# Initial GFS2 cluster setup — run ONCE after CDK deploy, also used for recovery.
# Safe to re-run (destroys and recreates the cluster; preserves data on the volume).
#
# Runs entirely over SSM Run Command — SSH (:22) and the REST API (:8080) are not
# exposed to the internet (security-group lockdown). Nodes are driven on-box by
# instance id. Requires the instances to have the SSM agent + AmazonSSMManagedInstanceCore
# (provided by the launch template/role).
#
# Usage: ./setup_cluster.sh <WRITER_IP_or_INSTANCE_ID> <VOLUME_ID>
set -euo pipefail

WRITER_ARG="${1:?Usage: $0 <WRITER_IP_or_INSTANCE_ID> <VOLUME_ID>}"
VOLUME_ID="${2:?Usage: $0 <WRITER_IP_or_INSTANCE_ID> <VOLUME_ID>}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="rocksdb-cluster"

# ── SSM helper ────────────────────────────────────────────────────────────────
# Run a shell command on an instance via SSM; echo stdout. The command is
# base64-wrapped so arbitrary quoting/escaping passes through untouched.
ssm_run() {
    local IID="$1" CMD="$2" WAIT="${3:-120}" CID ST B64 DEADLINE NOW
    B64=$(printf '%s' "${CMD}" | base64 | tr -d '\n')
    CID=$(aws ssm send-command --instance-ids "${IID}" \
        --document-name AWS-RunShellScript \
        --parameters commands="echo ${B64} | base64 -d | bash" \
        --query 'Command.CommandId' --output text --region "${REGION}" 2>/dev/null) || return 1
    NOW=$(date +%s); DEADLINE=$(( NOW + WAIT ))
    while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
        ST=$(aws ssm get-command-invocation --command-id "${CID}" --instance-id "${IID}" \
            --query 'Status' --output text --region "${REGION}" 2>/dev/null || echo "Pending")
        case "${ST}" in
            Success)
                aws ssm get-command-invocation --command-id "${CID}" --instance-id "${IID}" \
                    --query 'StandardOutputContent' --output text --region "${REGION}" 2>/dev/null
                return 0 ;;
            Failed|Cancelled|TimedOut) return 1 ;;
        esac
        sleep 3
    done
    return 1
}

resolve_id() {
    local TOK="$1"
    case "${TOK}" in i-*) echo "${TOK}"; return 0 ;; esac
    local RES
    RES=$(aws ec2 describe-instances --region "${REGION}" \
        --filters "Name=instance-state-name,Values=running" "Name=ip-address,Values=${TOK}" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "")
    if [ -z "${RES}" ] || [ "${RES}" = "None" ]; then
        RES=$(aws ec2 describe-instances --region "${REGION}" \
            --filters "Name=instance-state-name,Values=running" "Name=private-ip-address,Values=${TOK}" \
            --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "")
    fi
    { [ -z "${RES}" ] || [ "${RES}" = "None" ]; } && return 1
    echo "${RES}"
}

WRITER_ID=$(resolve_id "${WRITER_ARG}") || { echo "ERROR: cannot resolve writer ${WRITER_ARG}"; exit 1; }

# Shared cluster 'hacluster' password from SSM (created at bootstrap).
HACLUSTER_PW=$(aws ssm get-parameter --name "/${CLUSTER_NAME}/hacluster-password" \
    --with-decryption --query 'Parameter.Value' --output text --region "${REGION}" 2>/dev/null || echo "")

echo "==> Gathering node info..."
ALL_ATTACHMENTS=$(aws ec2 describe-volumes --volume-ids "${VOLUME_ID}" \
    --query 'Volumes[0].Attachments[*].InstanceId' --output text)

PRIV_IPS=""
HOST_MAP=""
ALL_IDS=()
for INST_ID in ${ALL_ATTACHMENTS}; do
    STATE=$(aws ec2 describe-instances --instance-ids "${INST_ID}" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
    [ "${STATE}" != "running" ] && continue
    PRIV=$(aws ec2 describe-instances --instance-ids "${INST_ID}" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    PRIV_IPS="${PRIV_IPS} ${PRIV}"
    HOST_MAP="${HOST_MAP:+${HOST_MAP};}${PRIV}:${INST_ID}"
    ALL_IDS+=("${INST_ID}")
done
PRIV_IPS=$(echo ${PRIV_IPS} | xargs)
echo "  Writer: ${WRITER_ID}"
echo "  Nodes: ${PRIV_IPS}"
echo "  Host map: ${HOST_MAP}"

VOL_SERIAL=$(echo "${VOLUME_ID}" | sed 's/-//')
DEVICE_BY_ID="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_SERIAL}"

# Force-stop cluster services on ALL nodes before setup (prevents pcsd hangs)
echo "==> Force-stopping cluster services on all nodes..."
for ID in "${ALL_IDS[@]}"; do
    echo "  Stopping ${ID}..."
    ssm_run "${ID}" "
        sudo systemctl stop rocksdb.service 2>/dev/null || true
        sudo systemctl stop cluster-watcher.service 2>/dev/null || true
        sudo killall -9 corosync pacemakerd pacemaker-controld pacemaker-attrd pacemaker-fenced pacemaker-schedulerd pacemaker-based 2>/dev/null || true
        sudo systemctl stop pacemaker corosync 2>/dev/null || true
        sudo systemctl start pcsd 2>/dev/null || true
        echo stopped
    " 60 >/dev/null || echo "    (could not reach ${ID}, continuing)"
done
sleep 3

echo "==> Setting up cluster from writer (${WRITER_ID})..."
# Built locally with interpolated local vars (PRIV_IPS, HOST_MAP, etc.); remote
# expansions are escaped (\$) so they evaluate on the writer. base64 in ssm_run
# preserves all quoting.
WRITER_SCRIPT=$(cat <<EOS
set -e
echo '==> Authenticating nodes...'
sudo pcs host auth ${PRIV_IPS} -u hacluster -p '${HACLUSTER_PW}'

echo '==> Creating cluster...'
sudo pcs cluster setup ${CLUSTER_NAME} ${PRIV_IPS} --force

# Enable Last Man Standing BEFORE first start (LMS only engages on a fresh start).
sudo sed -i '/provider: corosync_votequorum/a\\        last_man_standing: 1\\n        last_man_standing_window: 10000' /etc/corosync/corosync.conf
sudo pcs cluster sync 2>/dev/null || true

echo '==> Starting cluster...'
sudo pcs cluster start --all
sudo pcs cluster enable --all
sleep 10

echo '==> Configuring fencing...'
sudo pcs property set stonith-enabled=true
sudo pcs property set no-quorum-policy=freeze
sudo pcs cluster config update totem token=30000 2>/dev/null || true
sudo pcs stonith create clusterfence fence_aws region=${REGION} pcmk_host_map='${HOST_MAP}' power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4

echo '==> Creating DLM resource...'
sudo pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true
sleep 15

echo '==> Checking GFS2 filesystem...'
HAS_GFS2=\$(sudo blkid ${DEVICE_BY_ID} 2>/dev/null | grep -c gfs2 || echo 0)
if [ "\${HAS_GFS2}" -gt 0 ]; then
    echo '  GFS2 already exists — skipping format'
else
    echo '  Formatting GFS2 (16 journals)...'
    echo y | sudo mkfs.gfs2 -j16 -p lock_dlm -t ${CLUSTER_NAME}:rocksdb -O ${DEVICE_BY_ID}
fi

echo '==> Creating GFS2 filesystem resource...'
sudo pcs resource create gfs2fs ocf:heartbeat:Filesystem device='${DEVICE_BY_ID}' directory='/data/rocksdb' fstype='gfs2' options='noatime' op monitor interval=10s on-fail=fence clone interleave=true
sudo pcs constraint order start dlm-clone then gfs2fs-clone
sudo pcs resource update gfs2fs op start timeout=120s op stop timeout=120s op monitor timeout=120s interval=30s
sleep 20

echo '==> Creating DB directory...'
sudo mkdir -p /data/rocksdb/db
sudo chmod 777 /data/rocksdb/db
sudo rm -f /data/rocksdb/db/LOCK

echo '==> Storing auth keys in SSM...'
/snap/bin/aws ssm put-parameter --name /${CLUSTER_NAME}/corosync-authkey --type SecureString --value "\$(sudo base64 -w0 /etc/corosync/authkey)" --overwrite --region ${REGION} 2>/dev/null || true
/snap/bin/aws ssm put-parameter --name /${CLUSTER_NAME}/pacemaker-authkey --type SecureString --value "\$(sudo base64 -w0 /etc/pacemaker/authkey)" --overwrite --region ${REGION} 2>/dev/null || true

NODE_COUNT=\$(grep -c 'nodeid:' /etc/corosync/corosync.conf || echo 0)
echo \$(( NODE_COUNT + 1 )) | sudo tee /data/rocksdb/.next_nodeid > /dev/null
sudo chmod 666 /data/rocksdb/.next_nodeid
echo "  ID counter set to \$(cat /data/rocksdb/.next_nodeid)"

echo '==> Purging CIB ghost entries...'
CONFIG_IPS=\$(grep 'ring0_addr:' /etc/corosync/corosync.conf | awk '{print \$2}')
CIB_NODES=\$(sudo cibadmin --query --xpath '//node' 2>/dev/null | grep -oP 'uname="\K[^"]+' || echo '')
for NODE in \${CIB_NODES}; do
    if ! echo "\${CONFIG_IPS}" | grep -q "\${NODE}"; then
        echo "  Purging CIB ghost: \${NODE}"
        sudo crm_node --force --remove "\${NODE}" 2>/dev/null || true
    fi
done

echo '==> Starting writer services...'
sudo systemctl start cluster-watcher.service
sudo systemctl enable cluster-watcher.service
sudo systemctl restart rocksdb.service
echo '==> Cluster setup complete.'
sudo pcs status | grep -E 'Online|Started|gfs2' || true
EOS
)
ssm_run "${WRITER_ID}" "${WRITER_SCRIPT}" 600 || { echo "ERROR: writer setup failed"; exit 1; }

echo "==> Starting reader services..."
for ID in "${ALL_IDS[@]}"; do
    [ "${ID}" = "${WRITER_ID}" ] && continue
    echo "  Starting rocksdb on ${ID}..."
    ssm_run "${ID}" "sudo systemctl restart rocksdb.service; echo restarted" 60 >/dev/null &
done
wait
sleep 5

echo "==> Verifying all services..."
for ID in "${ALL_IDS[@]}"; do
    HEALTH=$(ssm_run "${ID}" "curl -s --max-time 5 http://localhost:8080/health || echo 'not ready'" 60 || echo "unreachable")
    echo "  ${ID}: ${HEALTH}"
done

echo "==> Done."
