#!/usr/bin/env bash
# Promotes a reader to writer via the REST admin endpoints.
# If an existing writer is alive, demotes it to reader first.
#
# The REST API is no longer exposed to the internet (the security group only
# allows :8080 from the ALB, and /admin/* is blocked at the ALB). So admin calls
# are executed ON the target node via SSM Run Command, hitting http://localhost:8080.
# The admin bearer token is read from the node's own /etc/rocksdb/service.env, so
# the secret never leaves the instance. No SSH and no public access required.
#
# Usage: ./promote_reader.sh <READER_IP>   (public or private IP, or instance-id)
set -euo pipefail

READER_TOKEN_ARG="${1:?Usage: $0 <READER_IP_or_INSTANCE_ID>}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ── SSM helpers ───────────────────────────────────────────────────────────────
# Run a shell command on an instance via SSM Run Command; echo its stdout.
# The command is base64-wrapped to avoid all quoting/escaping issues.
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

# REST call executed on the target node's localhost. Reads the admin token from
# the node's own service.env, so it works for both admin and data endpoints.
# Usage: node_rest <instance_id> <METHOD> <path> [json_body]
node_rest() {
    local IID="$1" METHOD="$2" P="$3" BODY="${4:-}"
    local C="TOK=\$(grep -oP 'ADMIN_TOKEN=\\K.*' /etc/rocksdb/service.env 2>/dev/null);"
    C="${C} curl -s --max-time 30 -X ${METHOD} -H \"Authorization: Bearer \${TOK}\" -H 'Content-Type: application/json'"
    [ -n "${BODY}" ] && C="${C} --data '${BODY}'"
    C="${C} http://localhost:8080${P}"
    ssm_run "${IID}" "${C}"
}

# Resolve a public IP / private IP / instance-id token to an instance id.
resolve_id() {
    local TOK="$1" RES=""
    if [[ "${TOK}" == i-* ]]; then echo "${TOK}"; return 0; fi
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

READER_ID=$(resolve_id "${READER_TOKEN_ARG}") || { echo "ERROR: cannot resolve ${READER_TOKEN_ARG} to an instance"; exit 1; }
echo "==> [$(date +%H:%M:%S)] Promoting ${READER_TOKEN_ARG} (${READER_ID}) to writer..."

# ── Step 0: Demote existing writer if alive ───────────────────────────────────
EXISTING_WRITER_ID=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=RocksDB-Writer" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text --region "${REGION}" 2>/dev/null || echo "")

if [ -n "${EXISTING_WRITER_ID}" ] && [ "${EXISTING_WRITER_ID}" != "None" ] && \
   [ "${EXISTING_WRITER_ID}" != "${READER_ID}" ]; then
    echo "  Existing writer found: ${EXISTING_WRITER_ID} — demoting to reader..."
    node_rest "${EXISTING_WRITER_ID}" POST /admin/demote >/dev/null || true
    echo "  Waiting for old writer to switch to readonly..."
    for _w in $(seq 1 30); do
        RESP=$(node_rest "${EXISTING_WRITER_ID}" GET /health 2>/dev/null || echo "")
        if echo "${RESP}" | grep -q '"mode":"readonly"'; then
            echo "  Old writer confirmed readonly"
            break
        fi
        sleep 3
    done
    aws ec2 create-tags --region "${REGION}" --resources "${EXISTING_WRITER_ID}" \
        --tags Key=Name,Value=RocksDB-Reader Key=rocksdb-role,Value=reader 2>/dev/null || true
    EXISTING_ASG=$(aws autoscaling describe-auto-scaling-instances \
        --instance-ids "${EXISTING_WRITER_ID}" --region "${REGION}" \
        --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text 2>/dev/null || echo "")
    if [ -n "${EXISTING_ASG}" ] && [ "${EXISTING_ASG}" != "None" ]; then
        aws autoscaling set-instance-protection \
            --instance-ids "${EXISTING_WRITER_ID}" \
            --auto-scaling-group-name "${EXISTING_ASG}" \
            --no-protected-from-scale-in --region "${REGION}" 2>/dev/null || true
    fi
    echo "  Old writer demoted: ${EXISTING_WRITER_ID}"
fi

# Wait for the reader's REST service to be reachable
echo "  Waiting for REST service on ${READER_ID}..."
for _i in $(seq 1 30); do
    RESP=$(node_rest "${READER_ID}" GET /health 2>/dev/null || echo "")
    if echo "${RESP}" | grep -q '"status":"ok"'; then
        echo "  Service ready: ${RESP}"
        break
    fi
    sleep 5
done

# Promote (async — service restarts in background)
echo "  Sending promote request..."
node_rest "${READER_ID}" POST /admin/promote >/dev/null || true

echo "  Waiting for readwrite mode..."
for _i in $(seq 1 30); do
    RESP=$(node_rest "${READER_ID}" GET /health 2>/dev/null || echo "")
    if echo "${RESP}" | grep -q '"mode":"readwrite"'; then
        echo "  Promoted: ${RESP}"
        break
    fi
    sleep 3
done

# Start cluster watcher
echo "  Starting cluster watcher..."
node_rest "${READER_ID}" POST /admin/start-watcher >/dev/null || true

# Scale-in protection + SSM + tags for the new writer
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances \
    --instance-ids "${READER_ID}" --region "${REGION}" \
    --query 'AutoScalingInstances[0].AutoScalingGroupName' \
    --output text 2>/dev/null || echo "")
if [ -n "${ASG_NAME}" ] && [ "${ASG_NAME}" != "None" ]; then
    aws autoscaling set-instance-protection \
        --instance-ids "${READER_ID}" \
        --auto-scaling-group-name "${ASG_NAME}" \
        --protected-from-scale-in --region "${REGION}" || true
    echo "  Scale-in protection set"
fi

aws ssm put-parameter --name /rocksdb-cluster/writer-instance-id \
    --type String --value "${READER_ID}" --overwrite --region "${REGION}" || true
aws ec2 create-tags --region "${REGION}" --resources "${READER_ID}" \
    --tags Key=Name,Value=RocksDB-Writer Key=rocksdb-role,Value=writer || true
echo "  SSM + tags updated"

sleep 3
HEALTH=$(node_rest "${READER_ID}" GET /health 2>/dev/null || echo "")
echo "==> [$(date +%H:%M:%S)] ${READER_ID}: ${HEALTH}"
