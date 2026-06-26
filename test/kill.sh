#!/usr/bin/env bash
# Kill a node — mirrors the TUI `kill <id>` command.
# TUI _cmd_kill: resolve node -> ec2.terminate_instances([inst_id]).
# For a test we then verify the cluster auto-recovers to its current desired size
# (ASG relaunches the node; svc health returns to ok).
# Usage: test/kill.sh <node_id|public_ip|private_ip> [recover_timeout_min]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TOKEN="${1:?Usage: $0 <node_id|public_ip|private_ip> [recover_timeout_min]}"
TIMEOUT_MIN="${2:-20}"

RESOLVED=$(resolve_node "${TOKEN}") || fail "node '${TOKEN}' not found"
INST_ID=$(echo "${RESOLVED}" | awk '{print $1}')
PUB_IP=$(echo "${RESOLVED}" | awk '{print $2}')

WRITER_ID=$(get_writer_id 2>/dev/null || echo "")
if [ "${INST_ID}" = "${WRITER_ID}" ]; then
    echo "  WARNING: ${TOKEN} is the writer — TUI warns to promote a reader first"
fi

N=$(get_desired_capacity)
log "Kill ${TOKEN} -> terminate ${INST_ID} (${PUB_IP}); expect recovery to ${N}"
aws ec2 terminate-instances --instance-ids "${INST_ID}" --region "${REGION}" >/dev/null
pass "terminate issued for ${INST_ID}"

# Wait for ASG to relaunch and the cluster to return to N ready
WRITER_IP=$(get_writer_ip 2>/dev/null || echo "")
wait_for_cluster_nodes "${WRITER_IP}" "${N}" "${TIMEOUT_MIN}" || fail "cluster did not recover to ${N} after kill"
pass "cluster recovered to ${N} after kill"
