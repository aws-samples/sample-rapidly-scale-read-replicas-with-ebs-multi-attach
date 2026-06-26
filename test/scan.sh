#!/usr/bin/env bash
# Scan all records from a specific node — mirrors the TUI `scan <id>` command.
# TUI _cmd_scan: resolve node -> GET /scan -> {"records":[...]}.
# Optional [min_count] asserts at least that many records are returned.
# Usage: test/scan.sh <node_id|public_ip|private_ip> [min_count]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TOKEN="${1:?Usage: $0 <node> [min_count]}"
MIN_COUNT="${2:-}"

RESOLVED=$(resolve_node "${TOKEN}") || fail "node '${TOKEN}' not found"
INST_ID=$(echo "${RESOLVED}" | awk '{print $1}')
log "Scan node ${TOKEN} (${INST_ID})"

BODY=$(node_body "${INST_ID}" GET /scan 2>/dev/null || echo "")
COUNT=$(echo "${BODY}" | python3 -c "import sys,json;print(len(json.loads(sys.stdin.buffer.read().decode('latin-1')).get('records',[])))" 2>/dev/null || echo "0")
echo "  ${COUNT} records"
echo "${BODY}" | python3 -c "import sys,json
recs=json.loads(sys.stdin.buffer.read().decode('latin-1')).get('records',[])
for r in recs[:20]:
    print('   ', r.get('key',''), '=', (r.get('value','') or '')[:80])
" 2>/dev/null || true

if [ -n "${MIN_COUNT}" ]; then
    [ "${COUNT}" -ge "${MIN_COUNT}" ] 2>/dev/null && pass "scan ${TOKEN}: ${COUNT} >= ${MIN_COUNT}" \
        || fail "scan ${TOKEN}: expected >= ${MIN_COUNT} records, got ${COUNT}"
else
    pass "scan ${TOKEN}: ${COUNT} records"
fi
