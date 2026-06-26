#!/usr/bin/env bash
# Wraps fence_aws to handle already-terminated instances.
# Stock fence_aws fails for terminated instances, causing DLM to hang permanently.
# Exit codes:
#   status action: exit 2 = OFF (dead), exit 0 = ON (alive)
#   reboot/off action: exit 0 = success
INPUT=$(cat)
PLUG=$(echo "$INPUT" | grep -oP 'plug=\K[^\s|]+' | head -1)
REGION=$(echo "$INPUT" | grep -oP 'region=\K[^\s|]+' | head -1)
ACTION=$(echo "$INPUT" | grep -oP 'action=\K[^\s|]+' | head -1)
for A in "$@"; do case "$A" in -o) shift; ACTION="$1";; --action=*) ACTION="${A#*=}";; esac; done
[ -z "${REGION}" ] && REGION="us-east-1"
if [ "${ACTION}" = "metadata" ] || [ "${ACTION}" = "monitor" ] || [ "${ACTION}" = "list" ]; then
    echo "${INPUT}" | tr '|' '\n' | /usr/sbin/fence_aws.real "$@"; exit $?
fi
if [ -n "${PLUG}" ]; then
    STATE=$(/snap/bin/aws ec2 describe-instances --instance-ids "${PLUG}" --region "${REGION}" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "")
    case "${STATE}" in
        terminated|shutting-down)
            logger -t fence_aws "${PLUG} is ${STATE} action=${ACTION}"
            [ "${ACTION}" = "status" ] && exit 2
            exit 0 ;;
    esac
fi
echo "${INPUT}" | tr '|' '\n' | /usr/sbin/fence_aws.real "$@"
