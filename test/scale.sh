#!/usr/bin/env bash
# Scale the cluster to N nodes — mirrors the TUI `scale <N>` command exactly.
# TUI _cmd_scale: update-auto-scaling-group --desired-capacity N, then poll until
# ASG InService >= N and writer /cluster/nodes online >= N. We additionally require
# every InService node /health=ok (the TUI nodes-table "Svc Health" column).
# Usage: test/scale.sh <N> [timeout_min]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

N="${1:?Usage: $0 <N> [timeout_min]}"
TIMEOUT_MIN="${2:-25}"

ASG_NAME=$(get_asg_name)
WRITER_IP=$(get_writer_ip)
log "Scale -> ${N} (ASG: ${ASG_NAME}, writer: ${WRITER_IP})"

aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "${ASG_NAME}" --desired-capacity "${N}" --region "${REGION}"

wait_for_cluster_nodes "${WRITER_IP}" "${N}" "${TIMEOUT_MIN}" || fail "scale to ${N} did not reach ready"
pass "scale to ${N} complete"
