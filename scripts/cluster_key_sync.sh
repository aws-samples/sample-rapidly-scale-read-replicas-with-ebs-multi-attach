#!/usr/bin/env bash
# Poll SSM for auth key changes and update local copies (readers only).
set -uo pipefail
REGION=$(grep -oP 'REGION=\K.*' /etc/rocksdb/cluster.env 2>/dev/null || echo "us-east-1")
CLUSTER_NAME=$(grep -oP 'CLUSTER_NAME=\K.*' /etc/rocksdb/cluster.env 2>/dev/null || echo "rocksdb-cluster")
AWS=/snap/bin/aws

# Only run on readers — writer manages its own keys
MODE=$(grep -oP 'MODE=\K\w+' /etc/rocksdb/service.env 2>/dev/null || echo "readonly")
[ "${MODE}" = "readwrite" ] && exit 0

# Fetch current keys from SSM
SSM_CORO=$("$AWS" ssm get-parameter --name "/${CLUSTER_NAME}/corosync-authkey" \
    --with-decryption --query 'Parameter.Value' --output text --region "${REGION}" 2>/dev/null | tr -d '\n' || echo "")
[ -z "${SSM_CORO}" ] && exit 0

SSM_PACE=$("$AWS" ssm get-parameter --name "/${CLUSTER_NAME}/pacemaker-authkey" \
    --with-decryption --query 'Parameter.Value' --output text --region "${REGION}" 2>/dev/null | tr -d '\n' || echo "")

# Compare with local keys
LOCAL_CORO=$(base64 -w0 /etc/corosync/authkey 2>/dev/null || echo "")
LOCAL_PACE=$(base64 -w0 /etc/pacemaker/authkey 2>/dev/null || echo "")

if [ "${SSM_CORO}" = "${LOCAL_CORO}" ] && [ "${SSM_PACE}" = "${LOCAL_PACE}" ]; then
    exit 0
fi

logger -t cluster-key-sync "Auth keys changed in SSM — updating and restarting cluster services"

# Update local keys
echo "${SSM_CORO}" | base64 -d > /etc/corosync/authkey
echo "${SSM_PACE}" | base64 -d > /etc/pacemaker/authkey
chmod 400 /etc/corosync/authkey /etc/pacemaker/authkey

# Restart cluster services so they pick up the new keys
systemctl disable pacemaker corosync 2>/dev/null || true
systemctl stop pacemaker corosync 2>/dev/null || true
killall -9 corosync pacemakerd 2>/dev/null || true
rm -rf /var/lib/pacemaker/cib/ && mkdir -p /var/lib/pacemaker/cib
rm -rf /var/lib/corosync/ && mkdir -p /var/lib/corosync
systemctl restart pcsd 2>/dev/null || true

logger -t cluster-key-sync "Keys updated, waiting for watcher to start cluster"
