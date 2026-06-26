#!/usr/bin/env bash
# Tear down the stack.
#
# Pre-step (why it's needed): the writer sets EC2 Auto Scaling **scale-in protection**
# on itself during bootstrap. On `cdk destroy` the ASG is scaled to 0, but a protected
# instance is NOT terminated — so the writer lingers, its ENI keeps the Internet Gateway
# attached, and the delete stalls on `AWS::EC2::VPCGatewayAttachment` ("NotStabilized").
# Clearing instance protection (and killing stray stress-test loaders) lets the delete
# complete cleanly. All steps are idempotent and safe to re-run.
set -uo pipefail
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STACK_NAME="RocksDbStack"

echo "==> Clearing scale-in protection on ${STACK_NAME} ASG instances..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "${REGION}" \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${STACK_NAME}')].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null || echo "")

if [ -n "${ASG_NAME}" ] && [ "${ASG_NAME}" != "None" ]; then
    echo "    ASG: ${ASG_NAME}"
    # Stop protecting new instances and drain to 0 so the ASG can terminate everything.
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG_NAME}" \
        --region "${REGION}" --no-new-instances-protected-from-scale-in \
        --min-size 0 --desired-capacity 0 2>/dev/null || true
    # Clear protection on the instances that are already running (e.g. the writer).
    INST_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
        --region "${REGION}" --query 'AutoScalingGroups[0].Instances[].InstanceId' \
        --output text 2>/dev/null || echo "")
    if [ -n "${INST_IDS}" ] && [ "${INST_IDS}" != "None" ]; then
        aws autoscaling set-instance-protection --instance-ids ${INST_IDS} \
            --auto-scaling-group-name "${ASG_NAME}" --no-protected-from-scale-in \
            --region "${REGION}" 2>/dev/null || true
        echo "    Cleared protection on: ${INST_IDS}"
        # Terminate them explicitly and WAIT until they're gone. Without the wait,
        # `cdk destroy` races ahead and tries to delete the data volume while it's still
        # attached to a not-yet-terminated instance → DELETE_FAILED on AWS::EC2::Volume.
        echo "    Terminating ASG instances and waiting for termination..."
        aws ec2 terminate-instances --instance-ids ${INST_IDS} --region "${REGION}" >/dev/null 2>&1 || true
        aws ec2 wait instance-terminated --instance-ids ${INST_IDS} --region "${REGION}" 2>/dev/null || true
    fi
else
    echo "    No ${STACK_NAME} ASG found (already deleted?) — continuing."
fi

# Stray stress-test loaders aren't part of the stack but share the VPC; terminate them
# AND delete their security group (rocksdb-loader-sg). A leftover SG blocks VPC teardown
# (you can't delete a VPC that still contains a security group), which otherwise stalls
# the whole `cdk destroy`.
echo "==> Terminating any stray stress-test loaders..."
STRAY=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=rocksdb-loader" \
              "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
if [ -n "${STRAY}" ] && [ "${STRAY}" != "None" ]; then
    aws ec2 terminate-instances --instance-ids ${STRAY} --region "${REGION}" >/dev/null 2>&1 || true
    echo "    Terminated: ${STRAY}"
    aws ec2 wait instance-terminated --instance-ids ${STRAY} --region "${REGION}" 2>/dev/null || true
fi

echo "==> Deleting stray loader security group (if any)..."
LOADER_SGS=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=group-name,Values=rocksdb-loader-sg" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || echo "")
for SG in ${LOADER_SGS}; do
    { [ -z "${SG}" ] || [ "${SG}" = "None" ]; } && continue
    # Retry: the SG can't be deleted until loader ENIs have fully detached.
    for _i in $(seq 1 12); do
        if aws ec2 delete-security-group --group-id "${SG}" --region "${REGION}" 2>/dev/null; then
            echo "    deleted loader SG ${SG}"; break
        fi
        sleep 5
    done
done

echo "==> Terminating any stray AMI-builder instances..."
BUILDERS=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=rocksdb-ami-builder" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
if [ -n "${BUILDERS}" ] && [ "${BUILDERS}" != "None" ]; then
    aws ec2 terminate-instances --instance-ids ${BUILDERS} --region "${REGION}" >/dev/null 2>&1 || true
    echo "    Terminated: ${BUILDERS}"
fi

echo "==> Ensuring the data volume is detached (belt-and-suspenders)..."
# Even after instances are gone, make sure the stack's EBS volume(s) carry no lingering
# attachment before `cdk destroy` tries to delete them (an attached volume can't be
# deleted). Found by CloudFormation stack tag so we never touch an unrelated volume.
VOL_IDS=$(aws ec2 describe-volumes --region "${REGION}" \
    --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK_NAME}" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || echo "")
for VOL in ${VOL_IDS}; do
    { [ -z "${VOL}" ] || [ "${VOL}" = "None" ]; } && continue
    ATT=$(aws ec2 describe-volumes --volume-ids "${VOL}" --region "${REGION}" \
        --query 'Volumes[0].Attachments[].InstanceId' --output text 2>/dev/null || echo "")
    if [ -n "${ATT}" ] && [ "${ATT}" != "None" ]; then
        echo "    force-detaching ${VOL} (was attached to ${ATT})"
        aws ec2 detach-volume --volume-id "${VOL}" --force --region "${REGION}" >/dev/null 2>&1 || true
        aws ec2 wait volume-available --volume-ids "${VOL}" --region "${REGION}" 2>/dev/null || true
    fi
done

# ── Remove runtime-created SSM parameters (NOT CloudFormation-managed) ─────────
# The instances create these at boot via `aws ssm put-parameter`, so `cdk destroy`
# never removes them. Delete them so no secrets (cluster auth keys, hacluster
# password, admin token) or stale writer state linger after teardown. Runs before
# the stack delete so it always executes even if `cdk destroy` later fails.
# (volume-id is CloudFormation-managed and removed by `cdk destroy`.)
echo "==> Deleting runtime SSM parameters under /${STACK_NAME}..."
CLUSTER_NAME="rocksdb-cluster"
for P in corosync-authkey pacemaker-authkey hacluster-password admin-token writer-instance-id; do
    aws ssm delete-parameter --name "/${CLUSTER_NAME}/${P}" --region "${REGION}" 2>/dev/null \
        && echo "    deleted /${CLUSTER_NAME}/${P}" || true
done

echo "==> Destroying stack..."
if ! uv run cdk destroy --all --require-approval never --force; then
    echo "WARNING: cdk destroy did not complete — leaving AMI, snapshots, and key pair"
    echo "         in place (the stack may still reference them). Fix the failure and"
    echo "         re-run destroy.sh (the pre-steps above are idempotent)."
    exit 1
fi

# ── Clean up the custom AMI(s) + backing snapshots ────────────────────────────
# The AMI is built by scripts/build_ami.sh, NOT by CloudFormation, so `cdk destroy`
# never removes it. Left behind it keeps costing snapshot storage and piles up with
# every rebuild. Remove the AMI recorded in ami_id.txt plus any self-owned image that
# matches the build-name pattern, and delete each one's backing EBS snapshot.
echo "==> Cleaning up custom AMI(s) and snapshots..."
SCRIPT_DIR_D="$(cd "$(dirname "$0")" && pwd)"
AMI_FROM_FILE=""
[ -f "${SCRIPT_DIR_D}/ami_id.txt" ] && AMI_FROM_FILE="$(tr -d '[:space:]' < "${SCRIPT_DIR_D}/ami_id.txt" 2>/dev/null || echo "")"
PATTERN_AMIS=$(aws ec2 describe-images --owners self --region "${REGION}" \
    --filters "Name=name,Values=rocksdb-*-ubuntu2404-*" \
    --query 'Images[].ImageId' --output text 2>/dev/null || echo "")

SEEN=""
for AMI in ${AMI_FROM_FILE} ${PATTERN_AMIS}; do
    { [ -z "${AMI}" ] || [ "${AMI}" = "None" ]; } && continue
    case " ${SEEN} " in *" ${AMI} "*) continue ;; esac   # dedupe
    SEEN="${SEEN} ${AMI}"
    SNAPS=$(aws ec2 describe-images --image-ids "${AMI}" --region "${REGION}" \
        --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text 2>/dev/null || echo "")
    if aws ec2 deregister-image --image-id "${AMI}" --region "${REGION}" 2>/dev/null; then
        echo "    deregistered ${AMI}"
    fi
    for SNAP in ${SNAPS}; do
        { [ -z "${SNAP}" ] || [ "${SNAP}" = "None" ]; } && continue
        aws ec2 delete-snapshot --snapshot-id "${SNAP}" --region "${REGION}" 2>/dev/null \
            && echo "    deleted snapshot ${SNAP}" || true
    done
done

# Reset ami_id.txt so the next deploy starts from a clean slate (forces a fresh build).
: > "${SCRIPT_DIR_D}/ami_id.txt" 2>/dev/null || true

# ── Remove the EC2 key pair + local private key ───────────────────────────────
# build_ami.sh creates the `rocksdb-key` key pair (and writes scripts/rocksdb-key.pem)
# if absent, so removing both here leaves no orphans and the next build recreates them.
KEY_NAME="rocksdb-key"
echo "==> Deleting EC2 key pair '${KEY_NAME}' and local private key..."
aws ec2 delete-key-pair --key-name "${KEY_NAME}" --region "${REGION}" 2>/dev/null \
    && echo "    deleted key pair ${KEY_NAME}" || true
rm -f "${SCRIPT_DIR_D}/scripts/${KEY_NAME}.pem" 2>/dev/null \
    && echo "    removed local scripts/${KEY_NAME}.pem" || true

echo "==> Done."
