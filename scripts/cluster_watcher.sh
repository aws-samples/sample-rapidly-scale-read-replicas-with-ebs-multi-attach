#!/usr/bin/env bash
# Cluster watcher — runs on the writer node.
# Key principle: let pacemaker handle fencing naturally. Only clean up nodes
# AFTER fencing completes. Never remove nodes from corosync.conf while DLM
# is still waiting for fencing confirmation.
set -uo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <region>}"
REGION="${2:?Usage: $0 <cluster-name> <region>}"
POLL_INTERVAL=5
AWS="/snap/bin/aws"
ID_FILE="/data/rocksdb/.next_nodeid"
GFS2_MOUNT="/data/rocksdb"
# Deadlock-breaker: if a terminated "ghost" node lingers in corosync.conf that
# cleanup cannot remove (corosync runtime-nodelist drift makes node removal fail),
# the normal "don't add while stale" gate would block ALL new joins forever.
# After a ghost has blocked adds for this long, add pending joiners anyway.
STALE_FORCE_SECS=120

echo "==> Cluster watcher started for '${CLUSTER_NAME}' in ${REGION}"

MY_IP=$(hostname -I | awk '{print $1}')

# Cluster 'hacluster' password — shared secret in SSM (SecureString), created at
# bootstrap. Read it once at startup (retry briefly in case the watcher races the
# writer's first-boot creation). Used for every `pcs host auth` below.
HACLUSTER_PW=""
for _i in $(seq 1 30); do
    HACLUSTER_PW=$("$AWS" ssm get-parameter --name "/${CLUSTER_NAME}/hacluster-password" \
        --with-decryption --query 'Parameter.Value' --output text --region "${REGION}" 2>/dev/null || echo "")
    { [ -n "${HACLUSTER_PW}" ] && [ "${HACLUSTER_PW}" != "None" ]; } && break
    sleep 2
done

# Exact IP -> nodeid lookup from corosync.conf. Field-exact (==), so it never
# resolves a prefix-collision IP (e.g. 10.0.0.20 must NOT match 10.0.0.205).
conf_nodeid_of_ip() {
    awk -v ip="$1" '
        $1=="ring0_addr:" && $2==ip {found=1}
        found && $1=="nodeid:" {print $2; exit}
    ' /etc/corosync/corosync.conf 2>/dev/null
}

get_next_nodeid() {
    [ -f "${ID_FILE}" ] && cat "${ID_FILE}" || echo "2"
}

increment_nodeid() {
    echo "$(( $(get_next_nodeid) + 1 ))" > "${ID_FILE}"
}

# Ensure nodeid counter is above all nodeids currently in conf
sync_nodeid_counter() {
    local MAX_NID=1
    while IFS= read -r NID; do
        [ "${NID}" -gt "${MAX_NID}" ] && MAX_NID="${NID}"
    done < <(grep -oP 'nodeid:\s*\K\d+' /etc/corosync/corosync.conf 2>/dev/null || true)
    local CURRENT
    CURRENT=$(get_next_nodeid)
    if [ "${CURRENT}" -le "${MAX_NID}" ]; then
        echo $(( MAX_NID + 1 )) > "${ID_FILE}"
    fi
}

ensure_pcsd_auth() {
    [ -s /var/lib/pcsd/known-hosts ] && return
    pcs host auth "${MY_IP}" -u hacluster -p "${HACLUSTER_PW}" 2>&1 || true
    for IP in $(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}'); do
        [ "${IP}" = "${MY_IP}" ] && continue
        pcs host auth "${IP}" -u hacluster -p "${HACLUSTER_PW}" 2>&1 || true
    done
}

# Get IPs of instances currently InService in the ASG
get_live_asg_ips() {
    local MY_ID ASG_NAME
    local IMDS_TOKEN
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")
    MY_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
    [ -z "${MY_ID}" ] && return
    ASG_NAME=$("$AWS" autoscaling describe-auto-scaling-instances --instance-ids "${MY_ID}" \
        --region "${REGION}" --query 'AutoScalingInstances[0].AutoScalingGroupName' \
        --output text 2>/dev/null || echo "")
    [ -z "${ASG_NAME}" ] || [ "${ASG_NAME}" = "None" ] && return
    local _IDS
    _IDS=$("$AWS" autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${ASG_NAME}" --region "${REGION}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text 2>/dev/null || echo "")
    [ -z "${_IDS}" ] && return
    "$AWS" ec2 describe-instances --instance-ids ${_IDS} --region "${REGION}" \
        --query 'Reservations[].Instances[].PrivateIpAddress' --output text 2>/dev/null || echo ""
}

# Authoritative check: is there a RUNNING EC2 instance with this private IP?
# Used to protect joining nodes from removal. Unlike get_live_asg_ips (a single
# ASG snapshot that can transiently omit a node during rapid churn), this queries
# EC2 directly for the specific IP, so a live node is never mistaken for gone.
# This is the core guard against the "back-to-back kill" wedge: a joining node
# that is not yet in the corosync ring AND momentarily absent from the ASG
# snapshot must NOT be removed from corosync.conf.
instance_running_by_ip() {
    local IP="$1" IID
    IID=$("$AWS" ec2 describe-instances \
        --filters "Name=private-ip-address,Values=${IP}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${REGION}" 2>/dev/null || echo "")
    [ -n "${IID}" ] && [ "${IID}" != "None" ]
}

# ── Watchdog: terminate nodes stuck joining for too long ──────────────────────
# Backstop so no node can stay wedged indefinitely. If an instance has carried
# the rocksdb-join tag but failed to come Online for longer than JOIN_STUCK_SECS,
# terminate it — the ASG launches a clean replacement that joins from scratch.
JOIN_WATCH_DIR="/data/rocksdb/.join_watch"
JOIN_STUCK_SECS=360   # 6 min; a normal join completes in < 2 min

reap_stuck_join_nodes() {
    mountpoint -q "${GFS2_MOUNT}" 2>/dev/null || return
    mkdir -p "${JOIN_WATCH_DIR}" 2>/dev/null || true
    local NODES
    NODES=$("$AWS" ec2 describe-instances --region "${REGION}" \
        --filters "Name=tag:rocksdb-join,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[PrivateIpAddress,InstanceId]' \
        --output text 2>/dev/null || true)
    local SEEN=""
    while IFS=$'\t' read -r IP INST; do
        [ -z "${IP}" ] && continue
        SEEN="${SEEN} ${IP}"
        local MARK="${JOIN_WATCH_DIR}/${IP}"
        # Online now? clear the marker — it joined fine.
        if pcs status nodes corosync 2>/dev/null | grep -i online | grep -qw "${IP}"; then
            rm -f "${MARK}" 2>/dev/null || true
            continue
        fi
        if [ ! -f "${MARK}" ]; then
            date +%s > "${MARK}"
            continue
        fi
        local FIRST NOW AGE
        FIRST=$(cat "${MARK}" 2>/dev/null || echo 0)
        NOW=$(date +%s); AGE=$(( NOW - FIRST ))
        if [ "${AGE}" -ge "${JOIN_STUCK_SECS}" ]; then
            echo "  [$(date +%H:%M:%S)] WATCHDOG: ${IP} (${INST}) stuck joining ${AGE}s — terminating for clean relaunch"
            "$AWS" ec2 terminate-instances --instance-ids "${INST}" --region "${REGION}" 2>/dev/null || true
            rm -f "${MARK}" 2>/dev/null || true
        fi
    done <<< "${NODES}"
    # Drop markers for IPs that are no longer pending
    for f in "${JOIN_WATCH_DIR}"/*; do
        [ -e "${f}" ] || continue
        local bip; bip=$(basename "${f}")
        echo "${SEEN}" | grep -qw "${bip}" || rm -f "${f}" 2>/dev/null || true
    done
}

# ── Proactively fence_ack nodes that left corosync ring ──────────────────────
# This unblocks DLM immediately when nodes depart, without waiting for
# pacemaker to mark them OFFLINE (which can take 30+ seconds).
proactive_fence_ack() {
    local CURRENT_MEMBERS
    CURRENT_MEMBERS=$(corosync-cmapctl runtime.members 2>/dev/null | grep -oP 'ip=\K[^\s]+' || echo "")
    local CONFIG_IPS
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
    for NODE in ${CONFIG_IPS}; do
        [ "${NODE}" = "${MY_IP}" ] && continue
        # If node is in conf but NOT in current corosync membership, fence_ack it
        if [ -n "${CURRENT_MEMBERS}" ] && ! echo "${CURRENT_MEMBERS}" | grep -qw "${NODE}"; then
            local NODE_ID
            NODE_ID=$(conf_nodeid_of_ip "${NODE}")
            if [ -n "${NODE_ID}" ]; then
                dlm_tool fence_ack "${NODE_ID}" 2>/dev/null || true
                stonith_admin --confirm "${NODE}" 2>/dev/null || true
            fi
        fi
    done
    # Also fence_ack any DLM node IDs in "wait fencing" state
    local FAILED_IDS
    FAILED_IDS=$(dlm_tool ls -n 2>/dev/null | grep 'failed [1-9]' | grep -oP 'nodeid \K\d+' || echo "")
    for NID in ${FAILED_IDS}; do
        dlm_tool fence_ack "${NID}" 2>/dev/null || true
    done
}
ensure_journals() {
    mountpoint -q "${GFS2_MOUNT}" 2>/dev/null || return
    local DEVICE NODE_COUNT JOURNAL_COUNT
    DEVICE=$(mount | grep "${GFS2_MOUNT}" | awk '{print $1}' | head -1)
    [ -z "${DEVICE}" ] && return
    NODE_COUNT=$(grep -c 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null || echo "1")
    JOURNAL_COUNT=$(gfs2_tool journals "${GFS2_MOUNT}" 2>/dev/null | grep -c 'journal' || echo "0")
    if [ "${JOURNAL_COUNT}" -lt "${NODE_COUNT}" ]; then
        local ADD=$(( NODE_COUNT - JOURNAL_COUNT ))
        echo "  [$(date +%H:%M:%S)] Adding ${ADD} GFS2 journal(s) (have ${JOURNAL_COUNT}, need ${NODE_COUNT})"
        gfs2_jadd -j "${ADD}" "${GFS2_MOUNT}" 2>/dev/null || true
    fi
}

# ── Sync runtime nodelist with corosync.conf ──────────────────────────────────
# corosync-cfgtool -R fails with CS_ERR_INVALID_PARAM when conf has fewer nodes
# than the runtime nodelist. This function temporarily adds stale nodelist entries
# back to conf, does a successful reload (which clears them), then removes them.
# Must be called whenever conf and runtime nodelist are out of sync.
sync_runtime_nodelist() {
    local CONF_IPS
    CONF_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
    local NODELIST_IPS
    NODELIST_IPS=$(corosync-cmapctl nodelist 2>/dev/null | grep -oP 'ring0_addr.*=\s*\K\S+' || echo "")

    # Check if any nodelist entries are missing from conf
    local STALE=()
    for NL_IP in ${NODELIST_IPS}; do
        echo "${CONF_IPS}" | grep -qw "${NL_IP}" || STALE+=("${NL_IP}")
    done
    [ ${#STALE[@]} -eq 0 ] && return

    echo "  [$(date +%H:%M:%S)] Syncing runtime nodelist: ${#STALE[@]} stale entries (${STALE[*]})"

    # Temporarily add stale entries to conf with their ORIGINAL nodeids from runtime
    local TMPFILE
    TMPFILE=$(mktemp)
    cp /etc/corosync/corosync.conf "${TMPFILE}"
    for STALE_IP in "${STALE[@]}"; do
        # Get the original nodeid from the runtime nodelist
        local ORIG_NID
        ORIG_NID=$(corosync-cmapctl nodelist 2>/dev/null \
            | grep -A5 "ring0_addr.*${STALE_IP}" | grep -oP 'nodeid.*=\s*\K\d+' || echo "")
        [ -z "${ORIG_NID}" ] && continue
        awk -v ip="${STALE_IP}" -v nid="${ORIG_NID}" '
            /^}/ && !inserted && found_nodelist {
                printf "\n    node {\n        ring0_addr: %s\n        name: %s\n        nodeid: %s\n    }\n", ip, ip, nid
                inserted=1
            }
            /^nodelist/ { found_nodelist=1 }
            { print }
        ' "${TMPFILE}" > "${TMPFILE}.new" && mv "${TMPFILE}.new" "${TMPFILE}"
    done
    cp "${TMPFILE}" /etc/corosync/corosync.conf
    rm -f "${TMPFILE}"

    # Reload — should succeed now that conf matches runtime nodelist
    corosync-cfgtool -R 2>/dev/null && echo "  [$(date +%H:%M:%S)] Runtime nodelist synced" || \
        echo "  [$(date +%H:%M:%S)] Warning: reload still failed after sync"
    sleep 2

    # Remove the temporarily-added stale nodes
    for STALE_IP in "${STALE[@]}"; do
        pcs cluster node remove "${STALE_IP}" --force 2>/dev/null || \
            crm_node --force --remove "${STALE_IP}" 2>/dev/null || true
    done
}

# ── Clean up OFFLINE/terminated nodes ────────────────────────────────────────
cleanup_offline_nodes() {
    local LIVE_IPS
    LIVE_IPS=$(get_live_asg_ips)

    local CONFIG_IPS
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
    local CONF_CHANGED=false
    local NODES_TO_REMOVE=()

    for NODE in ${CONFIG_IPS}; do
        [ "${NODE}" = "${MY_IP}" ] && continue
        # Skip if still a live ASG member
        [ -n "${LIVE_IPS}" ] && echo "${LIVE_IPS}" | grep -qw "${NODE}" && continue
        # Authoritative guard: never remove a node whose EC2 instance is still
        # running. get_live_asg_ips can transiently omit a node during rapid
        # churn (back-to-back kills); a direct per-IP EC2 check cannot. This
        # also protects against get_live_asg_ips returning empty on an AWS hiccup
        # (which would otherwise mark every node for removal).
        if instance_running_by_ip "${NODE}"; then continue; fi
        NODES_TO_REMOVE+=("${NODE}")
    done

    [ ${#NODES_TO_REMOVE[@]} -eq 0 ] && {
        # Still purge CIB ghosts and lost members even if no conf changes needed
        _purge_cib_ghosts
        return
    }

    echo "  [$(date +%H:%M:%S)] Removing ${#NODES_TO_REMOVE[@]} terminated node(s): ${NODES_TO_REMOVE[*]}"

    # STEP 1: Fence all departed nodes and fence_ack DLM so it unblocks immediately
    for NODE in "${NODES_TO_REMOVE[@]}"; do
        stonith_admin --confirm "${NODE}" 2>/dev/null || true
        local NODE_ID
        NODE_ID=$(conf_nodeid_of_ip "${NODE}")
        [ -n "${NODE_ID}" ] && dlm_tool fence_ack "${NODE_ID}" 2>/dev/null || true
        crm_node --force --remove "${NODE}" 2>/dev/null || true
    done

    # STEP 2: Kill departed nodes from the corosync runtime ring using corosync-cfgtool -k,
    # then remove from conf, then reload to sync the nodelist.
    # Correct order per corosync docs:
    #   1. corosync-cfgtool -k <nodeid>  — removes from ring (node can't participate)
    #   2. pcs cluster node remove       — removes from conf
    #   3. corosync-cfgtool -R           — reload syncs nodelist with conf
    # Reference: https://lore.proxmox.com/pve-devel/965f2d05-7817-09ed-de1c-4205b2459faa@proxmox.com/t/
    for NODE in "${NODES_TO_REMOVE[@]}"; do
        local NODE_ID
        NODE_ID=$(conf_nodeid_of_ip "${NODE}")
        if [ -n "${NODE_ID}" ]; then
            corosync-cfgtool -k "${NODE_ID}" 2>/dev/null || true
            echo "  [$(date +%H:%M:%S)] Killed nodeid ${NODE_ID} (${NODE}) from ring"
        fi
    done
    sleep 1

    # Departed nodes are now out of the runtime ring, so Total votes already reflects
    # the LIVE count. Pin expected_votes here — BEFORE the slow per-node conf-removal
    # loop below (which can run for minutes on a 16->1 drop). Otherwise expected_votes
    # stays inflated for the whole cleanup window → not quorate → DLM heads to kern_stop,
    # and a data-path op landing in that window would freeze. The main-loop pin can't
    # cover this because it doesn't re-run while we're inside this function.
    pin_expected_votes 2>/dev/null || true

    # STEP 3: Now remove departed nodes from conf (runtime ring is clean)
    local REMOVED=()
    for NODE in "${NODES_TO_REMOVE[@]}"; do
        local IS_OFFLINE=false
        pcs status nodes 2>/dev/null | grep -iE 'offline|standby' | grep -qw "${NODE}" && IS_OFFLINE=true
        local MEMBER_STATUS
        MEMBER_STATUS=$(corosync-cmapctl runtime.members 2>/dev/null \
            | grep -A3 -F "ip(${NODE})" | grep -oP 'status.*=\s*\K\S+' || echo "absent")
        [ "${MEMBER_STATUS}" = "absent" ] || [ "${MEMBER_STATUS}" = "left" ] && IS_OFFLINE=true
        # After -k, node should be absent from nodelist
        local IN_NODELIST=false
        corosync-cmapctl nodelist 2>/dev/null | awk -F'=' '/ring0_addr/{gsub(/ /,"",$2);print $2}' \
            | grep -qxF "${NODE}" && IN_NODELIST=true

        if [ "${IS_OFFLINE}" = "true" ] && [ "${IN_NODELIST}" = "false" ]; then
            echo "  [$(date +%H:%M:%S)] Removing: ${NODE}"
            pcs cluster node remove "${NODE}" --force --skip-offline 2>/dev/null || \
                crm_node --force --remove "${NODE}" 2>/dev/null || true
            REMOVED+=("${NODE}")
            CONF_CHANGED=true
        elif [ "${IS_OFFLINE}" = "true" ] && [ "${IN_NODELIST}" = "true" ]; then
            # -k succeeded but node still in nodelist — remove from conf then reload
            echo "  [$(date +%H:%M:%S)] Removing ${NODE} from conf (killed from ring, reload will clear nodelist)"
            pcs cluster node remove "${NODE}" --force --skip-offline 2>/dev/null || \
                crm_node --force --remove "${NODE}" 2>/dev/null || true
            REMOVED+=("${NODE}")
            CONF_CHANGED=true
        fi
    done

    _purge_cib_ghosts

    if [ "${CONF_CHANGED}" = "true" ]; then
        local ALL_IPS
        ALL_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')

        for AIP in ${ALL_IPS}; do
            pcs host auth "${AIP}" -u hacluster -p "${HACLUSTER_PW}" 2>&1 || true
        done
        # Reload corosync so runtime nodelist matches the cleaned conf
        corosync-cfgtool -R 2>/dev/null || true
        # Rebuild fence map with only live nodes
        local FENCE_MAP=""
        for FIP in ${ALL_IPS}; do
            local FINST
            FINST=$("$AWS" ec2 describe-instances \
                --filters "Name=private-ip-address,Values=${FIP}" "Name=instance-state-name,Values=running" \
                --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${REGION}" 2>/dev/null)
            [ -n "${FINST}" ] && [ "${FINST}" != "None" ] && \
                FENCE_MAP="${FENCE_MAP:+${FENCE_MAP};}${FIP}:${FINST}"
        done
        [ -n "${FENCE_MAP}" ] && pcs stonith update clusterfence "pcmk_host_map=${FENCE_MAP}" 2>/dev/null || true
    fi

    pcs stonith history cleanup 2>/dev/null || true
    pcs resource cleanup 2>/dev/null || true

    # Pin expected_votes to the number of LIVE ring members — NOT the corosync.conf
    # entry count. Conf can retain un-removable "ghost" nodes (corosync can't shrink
    # its runtime nodelist via reload), and counting those inflates expected_votes
    # above the live node count → quorum lost → DLM enters kern_stop → all GFS2 I/O
    # freezes (a writer wedges with an unkillable dlm_lock D-state process).
    # Last Man Standing (set at cluster setup) maintains this automatically; this is a
    # belt-and-suspenders targeting the same value, so it never fights LMS.
    local LIVE_VOTES
    LIVE_VOTES=$(corosync-quorumtool -s 2>/dev/null | awk -F: '/Total votes/{gsub(/ /,"",$2);print $2}')
    [ "${LIVE_VOTES:-0}" -ge 1 ] || LIVE_VOTES=1
    corosync-quorumtool -e "${LIVE_VOTES}" 2>/dev/null || true
}

_purge_cib_ghosts() {
    # Purge CIB-only ghost nodes not in corosync.conf
    local CONFIG_IPS
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
    local CIB_NODES
    CIB_NODES=$(cibadmin --query --xpath '//node' 2>/dev/null | grep -oP 'uname="\K[^"]+' || echo "")
    for NODE in ${CIB_NODES}; do
        echo "${CONFIG_IPS}" | grep -qw "${NODE}" && continue
        [ "${NODE}" = "${MY_IP}" ] && continue
        crm_node --force --remove "${NODE}" 2>/dev/null || true
    done
    # Purge all crm_node entries (member or lost) not in corosync.conf.
    # This clears stale in-memory node→nodeid mappings that cause pacemaker
    # to reject new nodes with reused nodeids (S_PENDING election loop).
    while IFS= read -r LINE; do
        [ -z "${LINE}" ] && continue
        local LID LNAME
        LID=$(echo "${LINE}" | awk '{print $1}')
        LNAME=$(echo "${LINE}" | awk '{print $2}')
        [ "${LNAME}" = "${MY_IP}" ] && continue
        echo "${CONFIG_IPS}" | grep -qw "${LNAME}" && continue
        crm_node --force --remove "${LNAME}" 2>/dev/null || true
        crm_node --force --remove "${LID}" 2>/dev/null || true
    done < <(crm_node -l 2>/dev/null || true)
}

# ── Recover configured nodes that are offline but still in ASG ───────────────
recover_offline_asg_nodes() {
    local LIVE_IPS
    LIVE_IPS=$(get_live_asg_ips)
    [ -z "${LIVE_IPS}" ] && return

    local CONFIG_IPS
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')

    # First strip any dead nodes from conf so sync doesn't fail.
    # Use pcs cluster node remove so corosync processes the departure properly.
    # This keeps the runtime nodelist in sync with conf.
    local CONF_CHANGED=false
    for IP in ${CONFIG_IPS}; do
        [ "${IP}" = "${MY_IP}" ] && continue
        echo "${LIVE_IPS}" | grep -qw "${IP}" && continue
        # Authoritative guard: do NOT remove a node whose EC2 instance is still
        # running — it may be a joining node not yet in the corosync ring and
        # transiently absent from the ASG snapshot. Removing it here (while its
        # local conf was just wiped by `pcs cluster destroy`) is exactly what
        # wedged nodes during back-to-back kills.
        if instance_running_by_ip "${IP}"; then continue; fi
        # Only remove if absent from runtime nodelist (corosync already processed departure)
        local IN_NL=false
        corosync-cmapctl nodelist 2>/dev/null | awk -F'=' '/ring0_addr/{gsub(/ /,"",$2);print $2}' \
            | grep -qxF "${IP}" && IN_NL=true
        if [ "${IN_NL}" = "false" ]; then
            pcs cluster node remove "${IP}" --force 2>/dev/null || \
                crm_node --force --remove "${IP}" 2>/dev/null || true
            CONF_CHANGED=true
        fi
    done
    # Refresh after cleanup
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')

    local OFFLINE_IPS=()
    for IP in ${CONFIG_IPS}; do
        [ "${IP}" = "${MY_IP}" ] && continue
        # Only try to recover if it's still in the ASG (not terminated)
        echo "${LIVE_IPS}" | grep -qw "${IP}" || continue
        # And currently offline in corosync
        pcs status nodes corosync 2>/dev/null | grep -i online | grep -qw "${IP}" && continue
        OFFLINE_IPS+=("${IP}")
    done
    [ ${#OFFLINE_IPS[@]} -eq 0 ] && return

    echo "  [$(date +%H:%M:%S)] Recovering ${#OFFLINE_IPS[@]} offline ASG node(s): ${OFFLINE_IPS[*]}"
    pcs host auth "${OFFLINE_IPS[@]}" -u hacluster -p "${HACLUSTER_PW}" 2>&1 || true
    pcs cluster sync --request-timeout 10 2>&1 || true
    for IP in "${OFFLINE_IPS[@]}"; do
        pcs cluster start "${IP}" 2>&1 || true
        pcs cluster enable "${IP}" 2>&1 || true
    done
}

# ── Prune dead (ghost) nodes from corosync.conf — fast, scale-up safety ───────
# Removes node{} blocks whose EC2 instance is no longer running, via a direct file
# edit. This makes scale-up robust regardless of how far the slower, fuller
# cleanup_offline_nodes has progressed: a joining reader must receive a conf that
# does NOT reference dead IPs (a ghost-laden conf makes its corosync fail to start —
# HTTP 400) and `pcs cluster sync` must not block waiting on an unreachable ghost.
# Safety: never prunes MY_IP (the writer); only prunes an IP with NO running instance
# (authoritative per-IP EC2 check via instance_running_by_ip), so a live or joining
# node is never removed even if it is briefly missing from an ASG snapshot.
prune_dead_conf_nodes() {
    local CONF=/etc/corosync/corosync.conf
    local CONF_IPS PRUNED=false
    CONF_IPS=$(grep 'ring0_addr:' "${CONF}" 2>/dev/null | awk '{print $2}')
    for IP in ${CONF_IPS}; do
        [ "${IP}" = "${MY_IP}" ] && continue
        instance_running_by_ip "${IP}" && continue   # keep: instance still running
        local TMP BEFORE AFTER
        TMP=$(mktemp)
        BEFORE=$(grep -c 'ring0_addr:' "${CONF}" 2>/dev/null || echo 0)
        # Delete the whole `node { ... }` block that contains this ghost IP.
        awk -v ip="${IP}" '
            /^[[:space:]]*node[[:space:]]*\{/ { buf=$0"\n"; inblk=1; dead=0; next }
            inblk {
                buf=buf $0 "\n"
                if ($1=="ring0_addr:" && $2==ip) dead=1
                if ($0 ~ /^[[:space:]]*\}/) { if (!dead) printf "%s", buf; inblk=0; buf="" }
                next
            }
            { print }
        ' "${CONF}" > "${TMP}"
        AFTER=$(grep -c 'ring0_addr:' "${TMP}" 2>/dev/null || echo 0)
        if [ -s "${TMP}" ] && [ "${AFTER}" -lt "${BEFORE}" ]; then
            cp "${TMP}" "${CONF}"
            PRUNED=true
            echo "  [$(date +%H:%M:%S)] pruned ghost ${IP} from corosync.conf (instance not running)"
        fi
        rm -f "${TMP}"
    done
    if [ "${PRUNED}" = "true" ]; then
        # Push the cleaned conf to live peers and re-pin quorum to the live count.
        pcs cluster sync --request-timeout 10 2>/dev/null || true
        corosync-cfgtool -R 2>/dev/null || true
        pin_expected_votes 2>/dev/null || true
    fi
}

# ── Add new nodes tagged rocksdb-join ─────────────────────────────────────────
add_new_nodes() {
    local NODES
    NODES=$("$AWS" ec2 describe-instances \
        --region "${REGION}" \
        --filters "Name=tag:rocksdb-join,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[PrivateIpAddress,InstanceId]' \
        --output text 2>/dev/null || true)
    [ -z "${NODES}" ] && return

    local PENDING_IPS=() PENDING_IDS=()
    while IFS=$'\t' read -r IP INSTANCE_ID; do
        [ -z "${IP}" ] && continue
        if pcs status nodes corosync 2>/dev/null | grep -i online | grep -qw "${IP}"; then
            "$AWS" ec2 delete-tags --region "${REGION}" --resources "${INSTANCE_ID}" --tags Key=rocksdb-join 2>/dev/null || true
            continue
        fi
        PENDING_IPS+=("${IP}")
        PENDING_IDS+=("${INSTANCE_ID}")
    done <<< "${NODES}"
    [ ${#PENDING_IPS[@]} -eq 0 ] && return

    echo "==> [$(date +%H:%M:%S)] Adding ${#PENDING_IPS[@]} node(s) one at a time..."
    ensure_journals
    prune_dead_conf_nodes   # clean ghost entries first so joining nodes get a valid conf
    sync_nodeid_counter  # ensure counter is above all existing nodeids in conf

    # Add nodes one at a time using manual nodeid assignment.
    # CRITICAL: We assign nodeids from our monotonic counter (stored on GFS2).
    # This ensures new nodeids are always HIGHER than any in the runtime nodelist,
    # so corosync-cfgtool -R succeeds (it rejects changes to existing nodeid IPs,
    # but accepts adding new nodeids).
    for i in "${!PENDING_IPS[@]}"; do
        local IP="${PENDING_IPS[$i]}" INST="${PENDING_IDS[$i]}"

        local AUTH_OUT
        AUTH_OUT=$(pcs host auth "${IP}" -u hacluster -p "${HACLUSTER_PW}" 2>&1)
        if ! echo "${AUTH_OUT}" | grep -q "Authorized"; then
            echo "  Auth failed for ${IP}, skipping: ${AUTH_OUT}"
            continue
        fi
        echo "  ${IP}: Authorized"

        # Wipe stale cluster config on the new node
        pcs cluster destroy "${IP}" 2>/dev/null || true
        sleep 2
        pcs host auth "${IP}" -u hacluster -p "${HACLUSTER_PW}" 2>/dev/null || true

        # Membership check must be EXACT. A substring grep like
        # `grep "ring0_addr: ${IP}"` wrongly matches a longer IP that has this
        # IP as a prefix (e.g. 10.0.0.20 matches the existing 10.0.0.205 line),
        # so the new node is judged "already present", never added to conf,
        # never gets a config, and corosync can't start (HTTP 400 wedge).
        # Compare the ring0_addr field values exactly.
        if ! grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}' | grep -qxF "${IP}"; then
            # Assign nodeid from counter, skipping any already in use in conf
            local NODE_ID
            NODE_ID=$(get_next_nodeid)
            increment_nodeid
            # Skip nodeids already used in conf
            while grep -qP "nodeid:\s*${NODE_ID}\b" /etc/corosync/corosync.conf 2>/dev/null; do
                NODE_ID=$(get_next_nodeid)
                increment_nodeid
            done
            echo "  ${IP} → node ID ${NODE_ID}"
            local TMPFILE
            TMPFILE=$(mktemp)
            awk -v ip="${IP}" -v nid="${NODE_ID}" '
                /^}/ && !inserted && found_nodelist {
                    printf "\n    node {\n        ring0_addr: %s\n        name: %s\n        nodeid: %s\n    }\n", ip, ip, nid
                    inserted=1
                }
                /^nodelist/ { found_nodelist=1 }
                { print }
            ' /etc/corosync/corosync.conf > "${TMPFILE}"
            cp "${TMPFILE}" /etc/corosync/corosync.conf
            rm -f "${TMPFILE}"
        fi

        # Reload corosync on writer — succeeds because new nodeid > stale runtime entries.
        # Readers don't need explicit reload — they pick up new members naturally when
        # the new node joins the ring.
        # IMPORTANT: Start the node BEFORE reloading the writer's corosync.
        # If we reload first, the writer adds the new nodeid to its runtime nodelist and
        # starts sending knet probes to the new node. If the node isn't running yet,
        # the unanswered probes cause token losses in the ring.
        # By starting the node first, it's already running when the writer reloads,
        # so the knet session establishes immediately without disrupting the ring.

        # Sync conf to all online nodes + new node
        pcs cluster sync --request-timeout 10 2>&1 || true

        # Start the new node
        echo "  Starting ${IP}..."
        pcs cluster start "${IP}" 2>&1 || true
        pcs cluster enable "${IP}" 2>&1 || true

        # Wait for new node's corosync to start before reloading writer
        sleep 5

        # Now reload writer's corosync — new node is already running, knet session
        # establishes immediately, no token disruption
        corosync-cfgtool -R 2>/dev/null || true

        local JOINED=false
        for _w in $(seq 1 60); do
            # Lightweight membership check (corosync's own view) — returns in ms,
            # unlike `pcs status nodes corosync` which queries Pacemaker and is slow
            # at 16 nodes, making this poll detect the join several seconds sooner.
            corosync-quorumtool -l 2>/dev/null | grep -qw "${IP}" && JOINED=true && break
            sleep 1
        done
        if [ "${JOINED}" = "false" ]; then
            # Retry: reload writer corosync and restart the node via pcsd (TCP 2224,
            # authenticated by hacluster) — the proper remote mechanism.
            corosync-cfgtool -R 2>/dev/null || true
            sleep 3
            pcs cluster start "${IP}" 2>&1 || true
            for _w in $(seq 1 30); do
                corosync-quorumtool -l 2>/dev/null | grep -qw "${IP}" && JOINED=true && break
                sleep 1
            done
        fi

        if [ "${JOINED}" = "true" ]; then
            local SVC_STATUS
            SVC_STATUS=$(curl -s --max-time 5 "http://${IP}:8080/health" 2>/dev/null | grep -oP '"status":"\K[^"]+' || echo "")
            if [ "${SVC_STATUS}" = "ok" ]; then
                "$AWS" ec2 delete-tags --region "${REGION}" --resources "${INST}" --tags Key=rocksdb-join 2>/dev/null || true
                echo "  [$(date +%H:%M:%S)] ${IP} joined and svc ok"
            else
                echo "  [$(date +%H:%M:%S)] ${IP} joined but svc not ready — keeping join tag"
            fi
        else
            echo "  [$(date +%H:%M:%S)] ${IP} failed to join — keeping join tag for retry"
        fi
    done

    local FULL_MAP=""
    for CONF_IP in $(grep 'ring0_addr:' /etc/corosync/corosync.conf | awk '{print $2}'); do
        local CONF_INST
        CONF_INST=$("$AWS" ec2 describe-instances \
            --filters "Name=private-ip-address,Values=${CONF_IP}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${REGION}" 2>/dev/null)
        [ -n "${CONF_INST}" ] && [ "${CONF_INST}" != "None" ] && \
            FULL_MAP="${FULL_MAP:+${FULL_MAP};}${CONF_IP}:${CONF_INST}"
    done
    [ -n "${FULL_MAP}" ] && pcs stonith update clusterfence "pcmk_host_map=${FULL_MAP}" 2>/dev/null || true
    pcs stonith history cleanup 2>/dev/null || true
    pcs resource cleanup 2>/dev/null || true
    echo "  [$(date +%H:%M:%S)] Add complete"
}

# ── Pin expected_votes to live ring members EVERY loop ───────────────────────
# corosync.conf can retain un-removable ghosts (it can't shrink the runtime
# nodelist via reload). If expected_votes follows the conf count it inflates above
# the live node count, the live set loses quorum, and DLM enters kern_stop —
# freezing all GFS2 I/O (an unkillable dlm_lock D-state hang). Setting
# expected_votes to the LIVE ring-member count on every loop (not just when conf
# changes) keeps the live set quorate regardless of how many ghosts linger.
pin_expected_votes() {
    local LIVE CUR
    # Use "Total votes" from corosync-quorumtool -s as the live-member count. This is
    # the votes held by the node's CURRENT membership view (the live ring), and equals
    # 1 vote per live node. Do NOT parse `-l` for dotted-IP lines: that count is
    # unreliable (it can match extra/header lines and reflect lingering entries),
    # which previously inflated expected_votes and re-triggered the DLM freeze.
    LIVE=$(corosync-quorumtool -s 2>/dev/null | awk -F: '/Total votes/{gsub(/ /,"",$2);print $2}')
    [ "${LIVE:-0}" -ge 1 ] || return
    CUR=$(corosync-quorumtool -s 2>/dev/null | awk -F: '/Expected votes/{gsub(/ /,"",$2);print $2}')
    [ "${CUR}" = "${LIVE}" ] && return
    echo "  [$(date +%H:%M:%S)] pinning expected_votes ${CUR:-?} -> ${LIVE} (live total votes)"
    corosync-quorumtool -e "${LIVE}" 2>/dev/null || true
}

# ── Main loop ─────────────────────────────────────────────────────────────────
STALE_SINCE=0
while true; do
    ensure_pcsd_auth 2>/dev/null || true
    pin_expected_votes 2>/dev/null || true
    proactive_fence_ack 2>/dev/null || true
    cleanup_offline_nodes 2>/dev/null || true

    # Only run resource cleanup when cluster is stable (all conf nodes online)
    # Running it during active joins disrupts in-progress DLM/GFS2 resource starts
    CONF_COUNT=$(grep -c 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null || echo "0")
    ONLINE_COUNT=$(pcs status nodes corosync 2>/dev/null | grep -oP 'Online:.*' | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l || echo "0")
    if [ "${CONF_COUNT}" -le "${ONLINE_COUNT}" ]; then
        pcs stonith history cleanup 2>/dev/null || true
        pcs resource cleanup 2>/dev/null || true
    fi

    recover_offline_asg_nodes 2>/dev/null || true

    # Watchdog: terminate any node stuck joining too long (self-healing backstop)
    reap_stuck_join_nodes 2>/dev/null || true

    # Only add new nodes when no stale (terminated) nodes remain in corosync.conf
    # Prevents corosync reload from disrupting in-progress joins
    LIVE_IPS=$(get_live_asg_ips 2>/dev/null || echo "")
    CONFIG_IPS=$(grep 'ring0_addr:' /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
    STALE=false
    for _IP in ${CONFIG_IPS}; do
        [ "${_IP}" = "${MY_IP}" ] && continue
        [ -n "${LIVE_IPS}" ] && echo "${LIVE_IPS}" | grep -qw "${_IP}" && continue
        STALE=true; break
    done
    if [ "${STALE}" = "false" ]; then
        STALE_SINCE=0
        add_new_nodes 2>/dev/null || true
    else
        # A conf node isn't a live ASG member. Normally we wait for
        # cleanup_offline_nodes to remove it before adding (avoids reload churn
        # during joins). But a terminated ghost that cleanup CANNOT remove
        # (corosync runtime-nodelist drift → node removal fails) would block all
        # new joins indefinitely — the scale-up wedge. Backstop: once the stale
        # state has persisted with pending joiners, add them anyway.
        # add_new_nodes assigns monotonic-high nodeids, so growing conf reloads
        # fine even with a ghost present; the cluster stays functional while the
        # ghost is harmless (offline). Severe accumulated drift is reset by a
        # writer recycle (fresh corosync state).
        NOW=$(date +%s)
        [ "${STALE_SINCE}" -eq 0 ] && STALE_SINCE=${NOW}
        PENDING_JOIN=$("$AWS" ec2 describe-instances --region "${REGION}" \
            --filters "Name=tag:rocksdb-join,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || echo "")
        if [ -n "${PENDING_JOIN}" ] && [ "${PENDING_JOIN}" != "None" ] \
           && [ $(( NOW - STALE_SINCE )) -ge "${STALE_FORCE_SECS}" ]; then
            echo "  [$(date +%H:%M:%S)] Stale ghost in conf for $(( NOW - STALE_SINCE ))s with pending joiner(s) — forcing add (deadlock breaker)"
            add_new_nodes 2>/dev/null || true
        fi
    fi
    sleep "${POLL_INTERVAL}"
done
