#!/usr/bin/env bash
# Pre-load RocksDB via SST file ingestion — fastest possible bulk load.
# SSTs are generated directly on the writer (no HTTP overhead, no WAL).
#
# Runs entirely over SSM Run Command — the REST API (:8080) and SSH (:22) are not
# exposed to the internet (security-group lockdown), so the writer is driven on-box
# via SSM. The generator runs detached (systemd-run) and progress is streamed from
# its log, so large datasets don't hit any single-command time limit.
#
# Flow:
#   1. upload sst_generator.cc + runner to the writer (base64 via SSM)
#   2. compile on writer (RocksDB headers already present from the AMI build)
#   3. stop rocksdb.service (IngestExternalFile needs exclusive DB access)
#   4. run sst_generator detached + stream progress; ingest atomically
#   5. restart rocksdb.service
#
# Usage: ./01_preload_data.sh [--keys 100000000] [--value-size 1024] [--keys-per-sst 1000000]
set -euo pipefail
STRESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${STRESS_DIR}/../test/common.sh"

NUM_KEYS=100000000    # ~100 GB on disk (incompressible). Must fit the volume — see guard below.
VALUE_SIZE=1024       # bytes per value
KEYS_PER_SST=1000000  # 1M keys per SST file (~1GB each)

while [[ $# -gt 0 ]]; do
    case $1 in
        --keys)         NUM_KEYS="$2";     shift 2 ;;
        --value-size)   VALUE_SIZE="$2";   shift 2 ;;
        --keys-per-sst) KEYS_PER_SST="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

WRITER_IP=$(get_writer_ip)
{ [ -z "${WRITER_IP}" ] || [ "${WRITER_IP}" = "None" ]; } && { echo "ERROR: No writer found"; exit 1; }
WIID=$(iid_of "${WRITER_IP}") || { echo "ERROR: cannot resolve writer instance id"; exit 1; }
echo "Writer: ${WRITER_IP} (${WIID})"
echo "Loading ${NUM_KEYS} keys × ${VALUE_SIZE} bytes = ~$(( NUM_KEYS * VALUE_SIZE / 1024 / 1024 / 1024 ))GB"

# Disk-space guard (mirrors the TUI). Values are incompressible, so on-disk size
# ≈ keys × (value + ~32 B overhead). Refuse anything that would exceed 90% of the
# data volume — prevents the ENOSPC / stuck-preload that a too-large dataset causes.
VOL_ID=$(get_volume_id 2>/dev/null || echo "")
VOL_GIB=$(aws ec2 describe-volumes --volume-ids "${VOL_ID}" --query 'Volumes[0].Size' \
    --output text --region "${REGION}" 2>/dev/null || echo 0)
REQ_GIB=$(python3 -c "print(int(${NUM_KEYS} * (${VALUE_SIZE} + 32) / (1024**3)))")
echo "Dataset ≈ ${REQ_GIB} GiB on disk (incompressible) · volume ${VOL_GIB} GiB"
if [ "${VOL_GIB}" -gt 0 ] && [ "${REQ_GIB}" -gt "$(( VOL_GIB * 9 / 10 ))" ]; then
    echo "ERROR: dataset (~${REQ_GIB} GiB) exceeds 90% of the ${VOL_GIB} GiB volume."
    echo "       Lower --keys or grow the volume."
    exit 1
fi

HEALTH=$(node_body "${WRITER_IP}" GET /health 2>/dev/null || echo "")
echo "${HEALTH}" | grep -q '"mode":"readwrite"' || { echo "ERROR: Writer not in readwrite mode"; exit 1; }

# Upload sst_generator.cc + the detached runner script (base64 through SSM)
echo "Uploading sst_generator.cc + runner..."
SRC_B64=$(base64 < "${STRESS_DIR}/sst_generator.cc" | tr -d '\n')
RUNNER=$(cat <<RUNNER_EOF
#!/bin/bash
ulimit -n 524288
/tmp/sst_generator /data/rocksdb/db --destroy > /tmp/preload.log 2>&1
/tmp/sst_generator /data/rocksdb/db ${NUM_KEYS} ${VALUE_SIZE} /data/rocksdb/sst_bulk ${KEYS_PER_SST} >> /tmp/preload.log 2>&1
echo PRELOAD_EXIT_\$? >> /tmp/preload.log
RUNNER_EOF
)
RUNNER_B64=$(printf '%s' "${RUNNER}" | base64 | tr -d '\n')
ssm_run "${WIID}" "echo ${SRC_B64} | base64 -d > /tmp/sst_generator.cc; echo ${RUNNER_B64} | base64 -d > /tmp/preload_runner.sh" 120 >/dev/null \
    || { echo "ERROR: upload failed"; exit 1; }

echo "Compiling sst_generator on writer..."
OUT=$(ssm_run "${WIID}" \
    "g++ -O2 -std=c++17 /tmp/sst_generator.cc -I/usr/local/include -L/usr/local/lib \
     -lrocksdb -lsnappy -lz -llz4 -lzstd -ldl -lpthread -o /tmp/sst_generator && echo __OK__" 600)
echo "${OUT}" | grep -q __OK__ || { echo "ERROR: compile failed"; exit 1; }
echo "Compiled OK"

echo "Stopping rocksdb.service + preparing on writer..."
OUT=$(ssm_run "${WIID}" \
    "sudo systemctl stop rocksdb.service; sleep 2; \
     sudo chmod 777 /data/rocksdb/db; sudo chmod 666 /data/rocksdb/db/* 2>/dev/null; \
     sudo mkdir -p /data/rocksdb/sst_bulk; sudo chmod 777 /data/rocksdb/sst_bulk; \
     echo '* hard nofile 524288' | sudo tee /etc/security/limits.d/rocksdb.conf >/dev/null; \
     echo '* soft nofile 524288' | sudo tee -a /etc/security/limits.d/rocksdb.conf >/dev/null; \
     sudo sysctl -w fs.file-max=524288 >/dev/null; echo __OK__" 120)
echo "${OUT}" | grep -q __OK__ || {
    echo "ERROR: prep failed"
    ssm_run "${WIID}" "sudo systemctl start rocksdb.service" 60 >/dev/null
    exit 1
}

# Launch the generator DETACHED so it survives independently; stream progress.
echo "Running sst_generator (${NUM_KEYS} keys, ${KEYS_PER_SST} per SST)..."
ssm_run "${WIID}" "sudo systemd-run --unit=rocksdb-preload --collect bash /tmp/preload_runner.sh" 60 >/dev/null

PRELOAD_CAP=$(python3 -c "print(max(1200, int(${NUM_KEYS}/150000)+600))")
PSTART=$(date +%s); LAST=""; OK=false
while [ "$(( $(date +%s) - PSTART ))" -lt "${PRELOAD_CAP}" ]; do
    sleep 15
    ROWS=$(ssm_run "${WIID}" \
        "tail -n 1 /tmp/preload.log 2>/dev/null; grep -q PRELOAD_EXIT_ /tmp/preload.log 2>/dev/null && echo __DONE__" 60 || echo "")
    PROG=$(echo "${ROWS}" | grep -v __DONE__ | tail -1 || true)
    if [ -n "${PROG}" ] && [ "${PROG}" != "${LAST}" ]; then echo "  ${PROG}"; LAST="${PROG}"; fi
    if echo "${ROWS}" | grep -q __DONE__; then
        CODE=$(ssm_run "${WIID}" "grep -oP 'PRELOAD_EXIT_\\K[0-9]+' /tmp/preload.log | tail -1" 60 | tr -d '[:space:]')
        if [ "${CODE}" = "0" ]; then
            OK=true; echo "  preload complete"
        else
            TAIL=$(ssm_run "${WIID}" "tail -n 5 /tmp/preload.log" 60)
            echo "  preload failed (exit ${CODE}): ${TAIL}"
        fi
        break
    fi
done
if [ "${OK}" != "true" ]; then
    echo "ERROR: preload did not finish within $(( PRELOAD_CAP / 60 )) min — aborting"
    ssm_run "${WIID}" "sudo systemctl start rocksdb.service" 60 >/dev/null
    exit 1
fi

ssm_run "${WIID}" "sudo rm -rf /data/rocksdb/sst_bulk /tmp/sst_generator /tmp/sst_generator.cc /tmp/preload_runner.sh" 120 >/dev/null

echo "Restarting rocksdb.service..."
ssm_run "${WIID}" "sudo systemctl start rocksdb.service" 60 >/dev/null

# Wait for writer to be healthy again
wait_for_health "${WRITER_IP}" "readwrite" "writer"

# Verify a sample
echo ""
echo "Verifying sample keys..."
for KEY in "stress:0000000000000000" "stress:0000000000000001" "stress:0000000000000002"; do
    RESP=$(node_body "${WRITER_IP}" GET "/get?key=${KEY}" 2>/dev/null || echo "")
    if echo "${RESP}" | grep -q '"key"'; then
        echo "  OK: ${KEY}"
    else
        echo "  MISSING: ${KEY} -> ${RESP}"
    fi
done
echo "Preload done."
