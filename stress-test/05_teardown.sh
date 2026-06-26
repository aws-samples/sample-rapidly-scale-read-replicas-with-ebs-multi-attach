#!/usr/bin/env bash
# Terminate load generator instances and optionally scale down the cluster.
#
# Usage: ./05_teardown.sh [--keep-cluster]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test/common.sh"

KEEP_CLUSTER=false
[ "${1:-}" = "--keep-cluster" ] && KEEP_CLUSTER=true

# Terminate load generators
read -ra LOADER_IDS <<< "$(cat /tmp/loader_instance_ids.txt 2>/dev/null || echo "")"
if [ "${#LOADER_IDS[@]}" -gt 0 ]; then
    echo "Terminating load generators: ${LOADER_IDS[*]}"
    aws ec2 terminate-instances --instance-ids "${LOADER_IDS[@]}" --region "${REGION}" > /dev/null
    rm -f /tmp/loader_instance_ids.txt
    echo "Load generators terminated."
else
    echo "No loader instances found."
fi

# Also terminate any stray loaders by tag
read -ra STRAY <<< "$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=rocksdb-loader" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text --region "${REGION}" 2>/dev/null || echo "")"
if [ "${#STRAY[@]}" -gt 0 ]; then
    echo "Terminating stray loaders: ${STRAY[*]}"
    aws ec2 terminate-instances --instance-ids "${STRAY[@]}" --region "${REGION}" > /dev/null
fi

if [ "${KEEP_CLUSTER}" = "false" ]; then
    echo ""
    echo "Scaling cluster back to 1 (writer only)..."
    ASG_NAME=$(get_asg_name)
    if [ -n "${ASG_NAME}" ] && [ "${ASG_NAME}" != "None" ]; then
        aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "${ASG_NAME}" \
            --desired-capacity 1 --region "${REGION}"
        echo "Scale-down initiated. Use wait_for_cluster_nodes to confirm."
    fi
fi

# Clean up loader security group (wait for instances to terminate first)
echo "Cleaning up loader security group..."
VPC_ID=$(get_vpc_id 2>/dev/null || echo "")
if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ]; then
    LOADER_SG=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=rocksdb-loader-sg" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' --output text --region "${REGION}" 2>/dev/null || echo "")
    if [ -n "${LOADER_SG}" ] && [ "${LOADER_SG}" != "None" ]; then
        # Wait up to 60s for loader instances to terminate before deleting SG
        for _w in $(seq 1 12); do
            ACTIVE=$(aws ec2 describe-instances \
                --filters "Name=tag:Name,Values=rocksdb-loader" \
                          "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
                --query 'Reservations[].Instances[].InstanceId' \
                --output text --region "${REGION}" 2>/dev/null || echo "")
            [ -z "${ACTIVE}" ] && break
            sleep 5
        done
        aws ec2 delete-security-group --group-id "${LOADER_SG}" --region "${REGION}" 2>/dev/null \
            && echo "Loader SG ${LOADER_SG} deleted" || echo "SG delete deferred"
    fi
fi

echo "Teardown complete."
