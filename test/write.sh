#!/usr/bin/env bash
# Write a key — mirrors the TUI `write <key> <val>` command.
# TUI _cmd_write: POST /put {"key","value"} to the writer (Connection: close), expect status:ok.
# Usage: test/write.sh <key> <value>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

KEY="${1:?Usage: $0 <key> <value>}"
VALUE="${2:?Usage: $0 <key> <value>}"

WRITER_IP=$(get_writer_ip)
[ -z "${WRITER_IP}" ] || [ "${WRITER_IP}" = "None" ] && fail "no writer found"
log "Write ${KEY}=${VALUE} -> writer ${WRITER_IP}"
write_key "${WRITER_IP}" "${KEY}" "${VALUE}" || fail "write failed"
pass "wrote ${KEY}"
