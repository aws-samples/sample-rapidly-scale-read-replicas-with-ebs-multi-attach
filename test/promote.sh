#!/usr/bin/env bash
# Promote a reader to writer — mirrors the TUI `promote <id>` command (normal path).
# TUI _cmd_promote: demote current writer (/admin/demote, wait readonly, retag reader,
# drop scale-in protection) -> promote target (/admin/promote, wait readwrite) ->
# /admin/start-watcher -> set scale-in protection -> update SSM writer-instance-id + tags.
# The current writer is NOT terminated (that would be a failover/kill test, not promote).
# scripts/promote_reader.sh performs this exact sequence.
# Usage: test/promote.sh [reader_public_ip]   (defaults to first InService reader)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ASG_NAME=$(get_asg_name)
OLD_WRITER=$(get_writer_ip)

TARGET_IP="${1:-}"
if [ -z "${TARGET_IP}" ]; then
    TARGET_IP=$(get_reader_ips | tr '\t' '\n' | awk 'NF{print; exit}')
fi
[ -z "${TARGET_IP}" ] && fail "no reader available to promote"

# Cluster size is unchanged by a promote — read current desired capacity for readiness wait
N=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].DesiredCapacity' --output text --region "${REGION}")

log "Promote ${TARGET_IP} -> writer (old writer ${OLD_WRITER} demotes to reader, stays up). Cluster size=${N}"
bash "${REPO_DIR}/scripts/promote_reader.sh" "${TARGET_IP}" || fail "promote_reader.sh failed"

# Confirm the new writer is readwrite and the cluster returns to full readiness
wait_for_health "${TARGET_IP}" "readwrite" "New writer ${TARGET_IP}" || fail "new writer not readwrite"
wait_for_cluster_nodes "${TARGET_IP}" "${N}" "15" || fail "cluster not ready after promote"

NEW_WRITER=$(get_writer_ip)
[ "${NEW_WRITER}" = "${OLD_WRITER}" ] && echo "  WARNING: writer IP unchanged (${NEW_WRITER})"
pass "promote complete — new writer: ${NEW_WRITER}"
