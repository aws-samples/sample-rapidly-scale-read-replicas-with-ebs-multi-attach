#!/usr/bin/env bash
# Scale ASG to maximum: 1 writer + 15 readers (16 total).
# Records detailed timing for each phase of the scale-up.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test/common.sh"

TARGET=16

ts() { date +%s; }
elapsed() { local _now; _now="$(ts)"; echo "$(( _now - T0 ))"; }
log_phase() {
    local NOW; NOW=$(ts)
    local SINCE_LAST=$(( NOW - LAST_TS ))
    local SINCE_START=$(( NOW - T0 ))
    echo "  [+${SINCE_START}s | phase=${SINCE_LAST}s] $*"
    LAST_TS=${NOW}
}

T0=$(ts)
LAST_TS=${T0}

ASG_NAME=$(get_asg_name)
WRITER_IP=$(get_writer_ip)

echo "================================================================"
echo "  Scale to max: 1 writer + 15 readers (${TARGET} total)"
echo "  Start: $(date)"
echo "================================================================"

# Phase 1: issue the ASG scale-up
log_phase "Issuing ASG desired-capacity=${TARGET}..."
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "${ASG_NAME}" \
    --desired-capacity "${TARGET}" \
    --region "${REGION}"
log_phase "ASG API call complete"

# Phase 2: poll until all instances are InService in ASG
echo ""
echo "--- Phase 2: waiting for ASG InService ---"
while true; do
    INSERVICE=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${ASG_NAME}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text --region "${REGION}" 2>/dev/null | wc -w | tr -d ' ')
    echo "  [+$(elapsed)s] ASG InService: ${INSERVICE}/${TARGET}"
    [ "${INSERVICE}" -ge "${TARGET}" ] && break
    sleep 5
done
log_phase "All ${TARGET} instances InService in ASG"

# Phase 3: poll until all instances pass ALB health check
echo ""
echo "--- Phase 3: waiting for ALB healthy targets ---"
# Use the target group actually attached to the ASG — there may be orphaned
# RocksD-ReadT-* groups from prior deploys, so matching by name is ambiguous.
TG_ARN=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${ASG_NAME}" --region "${REGION}" \
    --query 'AutoScalingGroups[0].TargetGroupARNs[0]' --output text 2>/dev/null)
while true; do
    HEALTHY=$(aws elbv2 describe-target-health \
        --target-group-arn "${TG_ARN}" --region "${REGION}" \
        --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' \
        --output text 2>/dev/null | wc -w | tr -d ' ')
    echo "  [+$(elapsed)s] ALB healthy: ${HEALTHY}/${TARGET}"
    [ "${HEALTHY}" -ge "${TARGET}" ] && break
    sleep 5
done
log_phase "All ${TARGET} instances healthy in ALB"

# Phase 4: poll until cluster shows all nodes Online
echo ""
echo "--- Phase 4: waiting for cluster membership ---"
STABLE=0
while true; do
    ONLINE=$(node_body "${WRITER_IP}" GET /cluster/nodes 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('online',0))" 2>/dev/null || echo "0")
    echo "  [+$(elapsed)s] Cluster Online: ${ONLINE}/${TARGET}"
    if [ "${ONLINE}" = "${TARGET}" ]; then
        STABLE=$(( STABLE + 1 ))
        [ "${STABLE}" -ge 2 ] && break
    else
        STABLE=0
    fi
    sleep 5
done
log_phase "Cluster stable at ${TARGET} Online nodes"

# Summary
TOTAL=$(elapsed)
echo ""
echo "================================================================"
echo "  Scale-up complete in ${TOTAL}s"
echo "  $(date)"
echo "================================================================"
echo ""
echo "Cluster nodes:"
node_body "${WRITER_IP}" GET /cluster/nodes | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  Online: {d[\"online\"]}')
for n in d['nodes']:
    print(f'    {n}')
"
ALB_DNS=$(get_alb_dns)
echo ""
echo "ALB: http://${ALB_DNS}"
echo "Writer: http://${WRITER_IP}:8080"
