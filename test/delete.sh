#!/usr/bin/env bash
# Delete a key — mirrors the TUI `delete <key>` command.
# TUI _cmd_delete: POST /delete {"key"} to the writer (Connection: close), expect status:ok.
# Usage: test/delete.sh <key>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

KEY="${1:?Usage: $0 <key>}"
WRITER_IP=$(get_writer_ip)
[ -z "${WRITER_IP}" ] || [ "${WRITER_IP}" = "None" ] && fail "no writer found"
log "Delete ${KEY} -> writer ${WRITER_IP}"

RESP=$(node_body "${WRITER_IP}" POST /delete "{\"key\":\"${KEY}\"}" 2>/dev/null || echo "")
echo "  response: ${RESP}"
echo "${RESP}" | grep -q '"status":"ok"' && pass "deleted ${KEY}" || fail "delete failed: ${RESP}"
