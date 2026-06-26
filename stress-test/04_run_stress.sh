#!/usr/bin/env bash
# Monitor the stress test in real time using CloudWatch + REST endpoints.
# Loaders run autonomously (started by UserData in 03_launch_loaders.sh).
# No SSH needed — all metrics come from CloudWatch and the writer REST API.
#
# Usage: ./04_run_stress.sh [--duration 300] [--interval 10]
set -euo pipefail
STRESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${STRESS_DIR}/../test/common.sh"

DURATION=1200  # seconds to monitor
INTERVAL=30    # metrics reporting interval (seconds)
RESULTS_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration)     DURATION="$2";     shift 2 ;;
        --interval)     INTERVAL="$2";     shift 2 ;;
        --results-file) RESULTS_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

ALB_DNS=$(get_alb_dns)
WRITER_IP=$(get_writer_ip)
VOLUME_ID=$(get_volume_id)

[ -z "${ALB_DNS}" ]   && echo "ERROR: No ALB found"    && exit 1
[ -z "${WRITER_IP}" ] && echo "ERROR: No writer found" && exit 1
[ -z "${VOLUME_ID}" ] && echo "ERROR: No volume found" && exit 1

LOADER_IDS=$(cat /tmp/loader_instance_ids.txt 2>/dev/null || echo "")
[ -z "${LOADER_IDS}" ] && echo "ERROR: No loader instances found. Run 03_launch_loaders.sh first." && exit 1

# Default results file: stress-test/results/YYYYMMDD_HHMMSS.csv
if [ -z "${RESULTS_FILE}" ]; then
    RESULTS_DIR="${STRESS_DIR}/results"
    mkdir -p "${RESULTS_DIR}"
    RESULTS_FILE="${RESULTS_DIR}/$(date +%Y%m%d_%H%M%S).csv"
fi
echo "Results file: ${RESULTS_FILE}"
echo "elapsed_s,cluster_nodes,alb_rps,alb_p99_ms,alb_5xx,ebs_iops,ebs_mbs" > "${RESULTS_FILE}"

# macOS-compatible date arithmetic
ago_iso() {
    local secs="$1"
    python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) - timedelta(seconds=${secs})
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}
now_iso() {
    python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# Get ALB and TG ARNs once
ALB_ARN=$(aws elbv2 describe-load-balancers --region "${REGION}" \
    --query 'LoadBalancers[?contains(LoadBalancerName,`ReadA`)].LoadBalancerArn' \
    --output text 2>/dev/null | head -1 || echo "")
TG_ARN=$(aws elbv2 describe-target-groups --region "${REGION}" \
    --query 'TargetGroups[?contains(TargetGroupName,`ReadT`)].TargetGroupArn' \
    --output text 2>/dev/null | awk '{print $1}' || echo "")

# Shorten ARN suffixes for CloudWatch dimension format (app/name/id and targetgroup/name/id)
ALB_SUFFIX=$(echo "${ALB_ARN}" | sed 's|.*:loadbalancer/||' 2>/dev/null || echo "")
TG_SUFFIX=$(echo "${TG_ARN}"  | sed 's|.*:targetgroup/|targetgroup/|' 2>/dev/null || echo "")

cw_stat() {
    # cw_stat <namespace> <metric> <dim_name> <dim_value> <stat> <period>
    # Always uses 60s period (CW minimum) with 120s lookback to ensure data availability
    local NS="$1" METRIC="$2" DIM_NAME="$3" DIM_VALUE="$4" STAT="$5"
    local START END
    START=$(ago_iso 120)
    END=$(now_iso)
    aws cloudwatch get-metric-statistics \
        --namespace "${NS}" --metric-name "${METRIC}" \
        --dimensions "Name=${DIM_NAME},Value=${DIM_VALUE}" \
        --start-time "${START}" --end-time "${END}" \
        --period 60 --statistics "${STAT}" \
        --query 'sort_by(Datapoints,&Timestamp)[-1].'"${STAT}" \
        --output text --region "${REGION}" 2>/dev/null || echo "0"
}

echo "================================================================"
echo "  RocksDB Stress Test Monitor"
echo "  ALB:    http://${ALB_DNS}"
echo "  Writer: http://${WRITER_IP}:8080"
echo "  Volume: ${VOLUME_ID}"
echo "  Loaders: ${LOADER_IDS}"
echo "  Duration: ${DURATION}s | Interval: ${INTERVAL}s"
echo "================================================================"
echo ""
printf "%-8s | %-7s | %-10s | %-12s | %-8s | %-10s | %-9s\n" \
    "Time(s)" "Cluster" "ALB_RPS" "ALB_p99(ms)" "ALB_5xx" "EBS_IOPS" "EBS_MB/s"
echo "---------|---------|-----------|-------------|---------|-----------|----------"

START_TS=$(date +%s)
ELAPSED=0

while [ "${ELAPSED}" -lt "${DURATION}" ]; do
    sleep "${INTERVAL}"
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TS ))

    # Cluster node count via SSM (REST not exposed publicly)
    ONLINE=$(node_body "${WRITER_IP}" GET /cluster/nodes 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('online',0))" 2>/dev/null || echo "?")

    # All CloudWatch metrics use 60s period (minimum granularity for ALB and EBS)
    # EBS metrics
    EBS_READ_OPS=$(cw_stat  "AWS/EBS" "VolumeReadOps"   "VolumeId" "${VOLUME_ID}" "Sum")
    EBS_WRITE_OPS=$(cw_stat "AWS/EBS" "VolumeWriteOps"  "VolumeId" "${VOLUME_ID}" "Sum")
    EBS_READ_BYTES=$(cw_stat "AWS/EBS" "VolumeReadBytes" "VolumeId" "${VOLUME_ID}" "Sum")

    EBS_IOPS=$(python3 -c "
r=float('${EBS_READ_OPS}' or 0); w=float('${EBS_WRITE_OPS}' or 0)
print(int((r+w)/60))" 2>/dev/null || echo "?")
    EBS_MBS=$(python3 -c "
b=float('${EBS_READ_BYTES}' or 0)
print(round(b/60/1024/1024,1))" 2>/dev/null || echo "?")

    # ALB metrics
    ALB_RPS="?" ALB_P99="?" ALB_5XX="?"
    if [ -n "${ALB_SUFFIX}" ]; then
        RAW_REQ=$(cw_stat "AWS/ApplicationELB" "RequestCount" \
            "LoadBalancer" "${ALB_SUFFIX}" "Sum")
        ALB_RPS=$(python3 -c "v=float('${RAW_REQ}' or 0); print(int(v/60))" 2>/dev/null || echo "?")

        # p99 requires get-metric-data (percentile stats not in get-metric-statistics)
        P99_START=$(ago_iso 120)
        P99_END=$(now_iso)
        RAW_P99=$(aws cloudwatch get-metric-data --region "${REGION}" \
            --metric-data-queries "[{\"Id\":\"p99\",\"MetricStat\":{\"Metric\":{\"Namespace\":\"AWS/ApplicationELB\",\"MetricName\":\"TargetResponseTime\",\"Dimensions\":[{\"Name\":\"LoadBalancer\",\"Value\":\"${ALB_SUFFIX}\"}]},\"Period\":60,\"Stat\":\"p99\"}}]" \
            --start-time "${P99_START}" --end-time "${P99_END}" \
            --query 'MetricDataResults[0].Values[0]' --output text 2>/dev/null || echo "")
        [ -n "${RAW_P99}" ] && [ "${RAW_P99}" != "None" ] && \
            ALB_P99=$(python3 -c "print(round(float('${RAW_P99}')*1000,1))" 2>/dev/null || echo "?")

        RAW_5XX=$(cw_stat "AWS/ApplicationELB" "HTTPCode_Target_5XX_Count" \
            "LoadBalancer" "${ALB_SUFFIX}" "Sum")
        ALB_5XX=$(python3 -c "print(int(float('${RAW_5XX}' or 0)))" 2>/dev/null || echo "?")
    fi

    printf "%-8s | %-7s | %-10s | %-12s | %-8s | %-10s | %-9s\n" \
        "${ELAPSED}s" "${ONLINE}" "${ALB_RPS}" "${ALB_P99}" "${ALB_5XX}" "${EBS_IOPS}" "${EBS_MBS}"

    # Append to CSV
    echo "${ELAPSED},${ONLINE},${ALB_RPS},${ALB_P99},${ALB_5XX},${EBS_IOPS},${EBS_MBS}" >> "${RESULTS_FILE}"
done

echo ""
echo "================================================================"
echo "  Monitoring complete. Results saved to: ${RESULTS_FILE}"
echo "  Run 05_teardown.sh to clean up loaders."
echo "================================================================"
