#!/usr/bin/env bash
# Full TUI-capability test sequence, built from the TUI-aligned building blocks:
#   scale.sh  promote.sh  kill.sh  write.sh  read.sh  scan.sh  delete.sh
# Exercises every TUI command: scale, promote, kill, write, read, scan, delete.
#
# Sequence:
#   recycle onto new AMI (size 1)
#   write k1,k2 -> read k1 from writer -> scan writer
#   scale 1->8 -> read/scan from a reader (replication)
#   scale 8->3
#   promote a reader -> writer
#   write k3 to new writer -> read k3 from a reader
#   kill a reader -> recover to 3
#   delete k1 -> read k1 expect not-found
#   scale 3->16
#   scale 16->5
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SETTLE_SECS=45
NEW_AMI=$(cat "${REPO_DIR}/ami_id.txt" 2>/dev/null || echo "")
ts() { date -u +%H:%M:%S; }

# Pick a reader token (public IP) that is not the writer
a_reader() { get_reader_ips | tr '\t' '\n' | awk 'NF{print; exit}'; }

# Regression for the back-to-back-kill wedge: terminate TWO readers at once
# (no wait between — maximal concurrency, reproduces the race) and require the
# cluster to auto-recover to its current desired size.
kill_two_back_to_back() {
    local N; N=$(get_desired_capacity)
    local readers r1 r2 i1 i2
    readers=$(get_reader_ips | tr '\t' '\n' | awk 'NF')
    r1=$(echo "${readers}" | sed -n 1p); r2=$(echo "${readers}" | sed -n 2p)
    if [ -z "${r1}" ] || [ -z "${r2}" ]; then echo "  need >=2 readers to kill"; return 1; fi
    i1=$(aws ec2 describe-instances --filters "Name=ip-address,Values=${r1}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${REGION}")
    i2=$(aws ec2 describe-instances --filters "Name=ip-address,Values=${r2}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${REGION}")
    echo "  killing back-to-back: ${r1} (${i1}) + ${r2} (${i2}); expect recovery to ${N}"
    aws ec2 terminate-instances --instance-ids "${i1}" "${i2}" --region "${REGION}" >/dev/null
    wait_for_cluster_nodes "$(get_writer_ip)" "${N}" 20 || return 1
}

recycle() {
    local ASG; ASG=$(get_asg_name)
    echo ""; echo "=== [$(ts)] RECYCLE onto new AMI ${NEW_AMI} ==="
    # Force desired capacity to 1 first, so the ASG converges to a single fresh
    # writer regardless of the cluster's prior size (otherwise it relaunches to
    # the old desired count and "wait for size 1" never succeeds).
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG}" \
        --desired-capacity 1 --region "${REGION}" 2>/dev/null || true
    local IDS; IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
        --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text --region "${REGION}")
    echo "  terminating: ${IDS}"
    for id in ${IDS}; do
        aws autoscaling set-instance-protection --instance-ids "${id}" \
            --auto-scaling-group-name "${ASG}" --no-protected-from-scale-in --region "${REGION}" 2>/dev/null || true
        aws ec2 terminate-instances --instance-ids "${id}" --region "${REGION}" >/dev/null
    done
    echo "  [$(ts)] waiting for replacement writer (size 1)…"
    wait_for_cluster_nodes "$(get_writer_ip 2>/dev/null || echo '')" 1 20 || return 1
    local WID AMI; WID=$(get_writer_id)
    AMI=$(aws ec2 describe-instances --instance-ids "${WID}" \
        --query 'Reservations[0].Instances[0].ImageId' --output text --region "${REGION}")
    echo "  [$(ts)] new writer ${WID} AMI=${AMI} (expected ${NEW_AMI})"
    [ "${AMI}" = "${NEW_AMI}" ] || { echo "  [$(ts)] ERROR: writer not on new AMI"; return 1; }
    sleep "${SETTLE_SECS}"
}

STEP_NAMES=(); STEP_SECS=()
print_summary() {
    echo ""; echo "===== STEP DURATIONS ====="
    local i
    for i in "${!STEP_NAMES[@]}"; do
        printf '  %-44s %dm %02ds\n' "${STEP_NAMES[$i]}" $(( STEP_SECS[$i] / 60 )) $(( STEP_SECS[$i] % 60 ))
    done
}

step() {  # step <desc> <cmd...>
    local desc="$1"; shift
    local s; s=$(date +%s)
    echo ""; echo "########## [$(ts)] STEP: ${desc} ##########"
    if ! "$@"; then
        local e; e=$(date +%s)
        STEP_NAMES+=("${desc} (FAILED)"); STEP_SECS+=($(( e - s )))
        echo "########## [$(ts)] STEP FAILED: ${desc} ($(( (e-s)/60 ))m $(( (e-s)%60 ))s) ##########"
        print_summary
        return 1
    fi
    local e; e=$(date +%s)
    STEP_NAMES+=("${desc}"); STEP_SECS+=($(( e - s )))
    echo "########## [$(ts)] STEP OK: ${desc} ($(( (e-s)/60 ))m $(( (e-s)%60 ))s) ##########"
}

settle() { echo "  [$(ts)] settling ${SETTLE_SECS}s…"; sleep "${SETTLE_SECS}"; }

# Test data values (unique per run)
V1="v1-$(date +%s)"; V2="v2-$(date +%s)"; V3="v3-$(date +%s)"

echo "########## CUSTOM SEQUENCE START $(date -u +%Y-%m-%dT%H:%M:%SZ) — AMI ${NEW_AMI} ##########"

step "recycle"                  recycle                                   || exit 10

step "write k1,k2"              bash "${SCRIPT_DIR}/write.sh" "ckey:1" "${V1}" || exit 20
step "write k2"                 bash "${SCRIPT_DIR}/write.sh" "ckey:2" "${V2}" || exit 20
step "read k1 from writer"      bash "${SCRIPT_DIR}/read.sh" "$(get_writer_ip)" "ckey:1" "${V1}" || exit 21
step "scan writer (>=2)"        bash "${SCRIPT_DIR}/scan.sh" "$(get_writer_ip)" 2 || exit 22

step "scale 1->8"               bash "${SCRIPT_DIR}/scale.sh" 8 25         || exit 1
settle
step "read k1 from reader"      bash "${SCRIPT_DIR}/read.sh" "$(a_reader)" "ckey:1" "${V1}" || exit 23
step "scan reader (>=2)"        bash "${SCRIPT_DIR}/scan.sh" "$(a_reader)" 2 || exit 24

step "scale 8->3"               bash "${SCRIPT_DIR}/scale.sh" 3 15         || exit 2
settle

step "promote reader"           bash "${SCRIPT_DIR}/promote.sh"            || exit 3
settle
step "write k3 (new writer)"    bash "${SCRIPT_DIR}/write.sh" "ckey:3" "${V3}" || exit 25
step "read k3 from reader"      bash "${SCRIPT_DIR}/read.sh" "$(a_reader)" "ckey:3" "${V3}" || exit 26

step "kill a reader -> recover" bash "${SCRIPT_DIR}/kill.sh" "$(a_reader)" 20 || exit 4
settle

step "delete k1"                bash "${SCRIPT_DIR}/delete.sh" "ckey:1"    || exit 27
step "read k1 -> not found"     bash "${SCRIPT_DIR}/read.sh" "$(get_writer_ip)" "ckey:1" "ABSENT" || exit 28

step "scale 3->16"              bash "${SCRIPT_DIR}/scale.sh" 16 35        || exit 5
settle
step "kill 2 readers back-to-back -> recover"  kill_two_back_to_back     || exit 7
settle
step "scale 16->5"              bash "${SCRIPT_DIR}/scale.sh" 5 20         || exit 6

echo ""; echo "########## ALL STEPS PASSED $(date -u +%Y-%m-%dT%H:%M:%SZ) ##########"
print_summary
