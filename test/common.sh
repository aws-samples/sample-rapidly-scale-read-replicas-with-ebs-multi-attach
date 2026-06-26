#!/usr/bin/env bash
# Shared helpers sourced by all test scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
KEY_NAME="rocksdb-key"
KEY_PATH="${REPO_DIR}/scripts/${KEY_NAME}.pem"
SSH_OPTS=(-i "${KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10)
STACK_NAME="RocksDbStack"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="rocksdb-cluster"

# ── SSM-backed REST helpers ───────────────────────────────────────────────────
# The REST API (:8080) is no longer reachable from the internet (the security
# group only allows it from the ALB, and /admin/* is blocked at the ALB). So all
# per-node REST calls run ON the target node via SSM Run Command, hitting
# http://localhost:8080. The admin bearer token is read from the node's own
# /etc/rocksdb/service.env, so the secret never leaves the instance.
# ALB calls (port 80, /health /get /scan) still use plain curl.
SSM_MARK="<<<HTTPCODE>>>"

# Resolve a public IP / private IP / instance-id to an instance id.
iid_of() {
    local TOK="$1" RES=""
    [ -z "${TOK}" ] && return 1
    case "${TOK}" in i-*) echo "${TOK}"; return 0 ;; esac
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

# Run a shell command on an instance via SSM; echo its stdout (base64-wrapped to
# avoid quoting issues).
ssm_run() {
    local IID="$1" CMD="$2" CID ST B64
    B64=$(printf '%s' "${CMD}" | base64 | tr -d '\n')
    CID=$(aws ssm send-command --instance-ids "${IID}" \
        --document-name AWS-RunShellScript \
        --parameters commands="echo ${B64} | base64 -d | bash" \
        --query 'Command.CommandId' --output text --region "${REGION}" 2>/dev/null) || return 1
    for _i in $(seq 1 45); do
        ST=$(aws ssm get-command-invocation --command-id "${CID}" --instance-id "${IID}" \
            --query 'Status' --output text --region "${REGION}" 2>/dev/null || echo "Pending")
        case "${ST}" in
            Success)
                aws ssm get-command-invocation --command-id "${CID}" --instance-id "${IID}" \
                    --query 'StandardOutputContent' --output text --region "${REGION}" 2>/dev/null
                return 0 ;;
            Failed|Cancelled|TimedOut) return 1 ;;
        esac
        sleep 2
    done
    return 1
}

# node_req <ip|id> <METHOD> <path> [json_body] -> echoes "BODY<MARK>HTTPCODE"
node_req() {
    local IID METHOD="$2" P="$3" BODY="${4:-}" C
    IID=$(iid_of "$1") || return 1
    C="TOK=\$(grep -oP 'ADMIN_TOKEN=\\K.*' /etc/rocksdb/service.env 2>/dev/null);"
    C="${C} curl -s -w '${SSM_MARK}%{http_code}' --max-time 20 -X ${METHOD} -H \"Authorization: Bearer \${TOK}\" -H 'Content-Type: application/json'"
    [ -n "${BODY}" ] && C="${C} --data '${BODY}'"
    C="${C} http://localhost:8080${P}"
    ssm_run "${IID}" "${C}"
}

# Body-only / code-only convenience wrappers around node_req.
node_body() { local OUT; OUT=$(node_req "$@") || return 1; printf '%s' "${OUT%"${SSM_MARK}"*}"; }
node_code() { local OUT; OUT=$(node_req "$@") || return 1; printf '%s' "${OUT##*"${SSM_MARK}"}"; }

# http_get <url> -> body. Routes node :8080 URLs via SSM; ALB (:80) via curl.
http_get() {
    local URL="$1" HP HOST PATHQ
    case "${URL}" in
        http://*:8080/*)
            HP="${URL#http://}"; HOST="${HP%%:*}"; PATHQ="/${URL#*:8080/}"
            node_body "${HOST}" GET "${PATHQ}" ;;
        *) curl -s --max-time 10 "${URL}" 2>/dev/null || echo "" ;;
    esac
}

# ── Stack outputs ─────────────────────────────────────────────────────────────
get_asg_name() {
    aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`ASGName`].OutputValue' \
        --output text --region "${REGION}"
}

get_alb_dns() {
    aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`ReadAlbDns`].OutputValue' \
        --output text --region "${REGION}"
}

get_volume_id() {
    aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`DataVolumeId`].OutputValue' \
        --output text --region "${REGION}"
}

get_vpc_id() {
    aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text --region "${REGION}"
}

# ── Instance discovery ────────────────────────────────────────────────────────
get_writer_ip() {
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=RocksDB-Writer" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text --region "${REGION}"
}

get_writer_id() {
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=RocksDB-Writer" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text --region "${REGION}"
}

get_reader_ips() {
    # Only return readers that are InService in the ASG (not terminating)
    local ASG
    ASG=$(get_asg_name 2>/dev/null || echo "")
    if [ -n "${ASG}" ] && [ "${ASG}" != "None" ]; then
        local INSERVICE_IDS
        INSERVICE_IDS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "${ASG}" \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
            --output text --region "${REGION}" 2>/dev/null || echo "")
        [ -z "${INSERVICE_IDS}" ] && return
        aws ec2 describe-instances \
            --instance-ids ${INSERVICE_IDS} \
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=RocksDB-Reader" \
            --query 'Reservations[].Instances[].PublicIpAddress' \
            --output text --region "${REGION}" 2>/dev/null
    else
        aws ec2 describe-instances \
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=RocksDB-Reader" \
            --query 'Reservations[].Instances[].PublicIpAddress' \
            --output text --region "${REGION}"
    fi
}

# ── Wait helpers ──────────────────────────────────────────────────────────────
wait_for_health() {
    local IP="$1" EXPECTED_MODE="$2" LABEL="${3:-${1}}"
    echo "  Waiting for ${LABEL} to be ${EXPECTED_MODE}..."
    for _i in $(seq 1 60); do
        local RESP
        RESP=$(node_body "${IP}" GET /health 2>/dev/null || echo "")
        if echo "${RESP}" | grep -q "\"mode\":\"${EXPECTED_MODE}\""; then
            echo "  ${LABEL} ready (${EXPECTED_MODE})"
            return 0
        fi
        sleep 5
    done
    echo "  ERROR: ${LABEL} did not reach ${EXPECTED_MODE} after 5 min"
    return 1
}

wait_for_alb_healthy() {
    local ALB_DNS="$1"
    echo "  Waiting for ALB to have healthy targets..."
    for _i in $(seq 1 24); do
        local RESP
        RESP=$(curl -s --max-time 5 "http://${ALB_DNS}/health" 2>/dev/null || echo "")
        if echo "${RESP}" | grep -q '"status":"ok"'; then
            echo "  ALB healthy"
            return 0
        fi
        sleep 5
    done
    echo "  ERROR: ALB did not become healthy after 2 min"
    return 1
}

# Readiness check — mirrors exactly what the TUI considers a completed scale:
#   - ASG InService count == N   (tui _cmd_scale polls InService)
#   - writer /cluster/nodes online == N   (tui _cmd_scale polls cluster online)
#   - every InService node /health -> status:ok   (tui nodes table "Svc Health")
# Requires 2 consecutive good polls for stability.
# Usage: wait_for_cluster_nodes <WRITER_IP> <N> [timeout_min]
wait_for_cluster_nodes() {
    local WRITER_IP="$1" EXPECTED="$2" TIMEOUT_MIN="${3:-25}"
    local ASG deadline STABLE=0
    ASG=$(get_asg_name 2>/dev/null || echo "")
    deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
    echo "  Waiting for ${EXPECTED} ready (InService + cluster online + svc ok), timeout ${TIMEOUT_MIN}m..."
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        # Re-fetch writer IP each loop (it changes after a promote)
        local W; W=$(get_writer_ip 2>/dev/null || echo "")
        [ -z "${W}" ] || [ "${W}" = "None" ] && W="${WRITER_IP}"

        local INSERVICE=0 ONLINE=0 HEALTHY=0 TOTAL=0
        if [ -n "${ASG}" ] && [ "${ASG}" != "None" ]; then
            INSERVICE=$(aws autoscaling describe-auto-scaling-groups \
                --auto-scaling-group-names "${ASG}" \
                --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|length(@)' \
                --output text --region "${REGION}" 2>/dev/null || echo "0")
        fi
        if [ -n "${W}" ] && [ "${W}" != "None" ]; then
            ONLINE=$(node_body "${W}" GET /cluster/nodes 2>/dev/null \
                | python3 -c "import sys,json; print(json.load(sys.stdin).get('online',0))" 2>/dev/null || echo "0")
            local IP
            for IP in ${W} $(get_reader_ips 2>/dev/null || echo ""); do
                [ -z "${IP}" ] && continue
                TOTAL=$(( TOTAL + 1 ))
                local SVC
                SVC=$(node_body "${IP}" GET /health 2>/dev/null \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
                [ "${SVC}" = "ok" ] && HEALTHY=$(( HEALTHY + 1 ))
            done
        fi
        echo "    ... InService=${INSERVICE}/${EXPECTED} online=${ONLINE}/${EXPECTED} svc_ok=${HEALTHY}/${TOTAL}"
        if [ "${INSERVICE}" = "${EXPECTED}" ] && [ "${ONLINE}" = "${EXPECTED}" ] \
           && [ "${HEALTHY}" = "${EXPECTED}" ] && [ "${TOTAL}" = "${EXPECTED}" ]; then
            STABLE=$(( STABLE + 1 ))
            if [ "${STABLE}" -ge 2 ]; then
                echo "  Cluster READY at ${EXPECTED} (InService + online + all svc ok)"
                return 0
            fi
        else
            STABLE=0
        fi
        sleep 10
    done
    echo "  ERROR: Cluster did not reach ${EXPECTED} ready nodes within ${TIMEOUT_MIN}m"
    return 1
}

# ── Assertion helpers ─────────────────────────────────────────────────────────
assert_record_count() {
    local URL="$1" EXPECTED="$2" LABEL="$3"
    local RESP COUNT
    RESP=$(http_get "${URL}")
    [ -z "${RESP}" ] && RESP="[]"
    COUNT=$(echo "${RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else len(d.get('records',[])))" 2>/dev/null || echo "0")
    if [ "${COUNT}" = "${EXPECTED}" ]; then
        echo "  PASS  ${LABEL}: ${COUNT} records"
    else
        echo "  FAIL  ${LABEL}: expected ${EXPECTED} records, got ${COUNT}"
        echo "        Response: ${RESP}"
        return 1
    fi
}

assert_mode() {
    local IP="$1" EXPECTED_MODE="$2" LABEL="$3"
    local RESP MODE
    RESP=$(node_body "${IP}" GET /health 2>/dev/null || echo "")
    MODE=$(echo "${RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mode',''))" 2>/dev/null || echo "")
    if [ "${MODE}" = "${EXPECTED_MODE}" ]; then
        echo "  PASS  ${LABEL}: mode=${MODE}"
    else
        echo "  FAIL  ${LABEL}: expected mode=${EXPECTED_MODE}, got mode=${MODE}"
        return 1
    fi
}

write_key() {
    local WRITER_IP="$1" KEY="$2" VALUE="$3"
    local RESP
    for _retry in $(seq 1 30); do
        RESP=$(node_body "${WRITER_IP}" POST /put "{\"key\":\"${KEY}\",\"value\":\"${VALUE}\"}" 2>/dev/null || echo "")
        if echo "${RESP}" | grep -q '"status":"ok"'; then
            echo "  WRITE ${KEY}=${VALUE} -> ${RESP}"
            sleep 1
            return 0
        fi
        [ "${_retry}" -le 3 ] || echo "  WRITE ${KEY}=${VALUE} retry ${_retry}: ${RESP}"
        sleep 10
    done
    echo "  WRITE ${KEY}=${VALUE} FAILED after 30 retries (5 min)"
    return 1
}

log() { echo ""; echo "==> $*"; }
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; exit 1; }

# ── Node resolution (mirrors tui.py _resolve_node) ────────────────────────────
# Resolve a node token to "<instance_id> <pub_ip>".
# Accepts: corosync node ID (int), public IP, or private IP.
# Echoes "INSTANCE_ID PUB_IP" on success; returns 1 on failure.
resolve_node() {
    local TOKEN="$1"
    local WRITER_IP PRIV_IP=""
    WRITER_IP=$(get_writer_ip 2>/dev/null || echo "")
    # Integer token -> corosync node id; map to private IP via writer /cluster/nodeids
    if [[ "${TOKEN}" =~ ^[0-9]+$ ]] && [ -n "${WRITER_IP}" ] && [ "${WRITER_IP}" != "None" ]; then
        PRIV_IP=$(node_body "${WRITER_IP}" GET /cluster/nodeids 2>/dev/null \
            | python3 -c "import sys,json;m=json.load(sys.stdin).get('map',{});print(next((ip for ip,nid in m.items() if str(nid)=='${TOKEN}'),''))" 2>/dev/null || echo "")
    fi
    local VAL="${PRIV_IP:-${TOKEN}}"
    local RES=""
    # Try as private IP first (covers node-id resolution and private-IP tokens)
    RES=$(aws ec2 describe-instances \
        --filters "Name=private-ip-address,Values=${VAL}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' \
        --output text --region "${REGION}" 2>/dev/null || echo "")
    if [ -z "${RES}" ] || echo "${RES}" | grep -q "None"; then
        # Fall back to public IP
        RES=$(aws ec2 describe-instances \
            --filters "Name=ip-address,Values=${VAL}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' \
            --output text --region "${REGION}" 2>/dev/null || echo "")
    fi
    [ -z "${RES}" ] && return 1
    echo "${RES}" | grep -q "None" && return 1
    echo "${RES}" | awk '{print $1, $2}'
}

get_desired_capacity() {
    local ASG; ASG=$(get_asg_name)
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
        --query 'AutoScalingGroups[0].DesiredCapacity' --output text --region "${REGION}"
}
