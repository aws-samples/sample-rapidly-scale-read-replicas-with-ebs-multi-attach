#!/usr/bin/env bash
# Read a key from a specific node — mirrors the TUI `read <id> <key>` command.
# TUI _cmd_read: resolve node -> GET /get?key= ; 200 -> value, 404 -> not found.
# Optional [expected] asserts the returned value equals it.
# Use expected="ABSENT" to assert the key is NOT present (HTTP 404).
# Usage: test/read.sh <node_id|public_ip|private_ip> <key> [expected|ABSENT]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TOKEN="${1:?Usage: $0 <node> <key> [expected]}"
KEY="${2:?Usage: $0 <node> <key> [expected]}"
EXPECTED="${3:-}"

RESOLVED=$(resolve_node "${TOKEN}") || fail "node '${TOKEN}' not found"
INST_ID=$(echo "${RESOLVED}" | awk '{print $1}')
log "Read ${KEY} from node ${TOKEN} (${INST_ID})"

QKEY=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "${KEY}")
OUT=$(node_req "${INST_ID}" GET "/get?key=${QKEY}" 2>/dev/null || echo "")
BODY="${OUT%"${SSM_MARK}"*}"
CODE="${OUT##*"${SSM_MARK}"}"
[ -z "${CODE}" ] && CODE="000"

if [ "${CODE}" = "404" ]; then
    echo "  key not found: ${KEY}"
    [ "${EXPECTED}" = "ABSENT" ] && { pass "read ${KEY}: absent as expected"; exit 0; }
    [ -n "${EXPECTED}" ] && fail "expected '${EXPECTED}' but key not found"
    pass "read ${KEY}: not found"; exit 0
fi
[ "${CODE}" = "200" ] || fail "read error (HTTP ${CODE}): ${BODY}"
[ "${EXPECTED}" = "ABSENT" ] && fail "expected ${KEY} absent, but it is present"

VAL=$(echo "${BODY}" | python3 -c "import sys,json;print(json.loads(sys.stdin.buffer.read().decode('latin-1')).get('value',''))" 2>/dev/null || echo "")
echo "  ${KEY} = ${VAL}"
if [ -n "${EXPECTED}" ]; then
    [ "${VAL}" = "${EXPECTED}" ] && pass "read ${KEY} == '${EXPECTED}'" || fail "read ${KEY}: expected '${EXPECTED}', got '${VAL}'"
else
    pass "read ${KEY}"
fi
