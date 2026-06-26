#!/usr/bin/env bash
MY_IP=$(hostname -I | awk '{print $1}')
logger -t cluster-self-remove "Removing ${MY_IP} from cluster..."
systemctl stop rocksdb.service 2>/dev/null || true
# Try graceful stop first (flushes DLM locks). Timeout after 15s.
# If it hangs (DLM busy with another node's recovery), force-kill corosync
# so the surviving nodes detect the membership change via token timeout.
timeout 15 pcs cluster stop --force 2>/dev/null || {
    logger -t cluster-self-remove "pcs cluster stop timed out — force-killing corosync"
    killall -9 corosync pacemakerd pacemaker-controld pacemaker-attrd pacemaker-fenced pacemaker-schedulerd pacemaker-based dlm_controld 2>/dev/null || true
}
logger -t cluster-self-remove "Done."
