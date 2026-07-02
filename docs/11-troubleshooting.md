[← Stress Testing](10-stress-testing.md) · [Home](../README.md) · [API Reference →](12-api-reference.md)

# 11. Troubleshooting

A catalogue of the failure modes found during development, their root causes, and the fixes — plus recovery procedures. Most of these were discovered through repeated scale/promote/kill testing.

## The big one: surprise reboots cause membership churn

**Symptom.** During scale-up, freshly launched readers seemed to "fail, then rejoin" — the cluster looked unstable, and a `scale` could take a long time to settle.

**Investigation.** There were **no fencing events, no Corosync token-loss errors, and all departures were clean** (`QUORUM Sync left`). That ruled out networking, fencing, and quorum problems. The instance logs told the real story: each reader **rebooted itself** ~6–8 min after launch. `unattended-upgrades` had installed a newer AWS kernel on first boot and scheduled an automatic OS reboot (`auth.log`: "The system will reboot at …"). Because the deployed AMI was ~2 months old, there was a pending kernel update waiting.

**Why it looked like a cluster bug.** A reboot makes a node leave the Corosync ring and rejoin ~15–20 s later. Several readers doing this at staggered times *is* the membership churn that was observed — but it was caused by the OS, not the cluster software.

**Fix.** Harden the AMI so deployed nodes never auto-reboot (in `setup_phase2.sh`):
- `apt-get purge` and `systemctl mask` `unattended-upgrades`, plus mask the `apt-daily` / `apt-daily-upgrade` timers and services (masking survives even if the package returns as a dependency).
- Write `/etc/apt/apt.conf.d/99-disable-auto-upgrades` with `APT::Periodic::* "0"` and `Unattended-Upgrade::Automatic-Reboot "false"`.
- Disable cloud-init package updates.

Then rebuild the AMI and recycle nodes. The trade-off: no automatic in-place OS patching — patching is done by rebuilding the AMI and rolling the fleet (the right model for HA cluster nodes, where an uncoordinated reboot looks like a node failure).

**Verification.** A full `scale 1→8→3→promote→16→5` run after the fix showed zero churn — nodes joined one-at-a-time and stayed.

> **Also: deploy on a freshly built AMI.** The hardening above stops *unattended-upgrades* from rebooting deployed nodes, but a **stale AMI** can still carry a pending OS/kernel update that a node applies and reboots for on first boot — interrupting the writer's cluster bootstrap before it finishes (leaving `rocksdb.service` looping and the watcher unstarted). Rebuilding the AMI bakes in the current kernel, so deployed instances have nothing pending. Rule of thumb: deploy on a recently built image; if reusing an older one, verify a test instance has **no `/var/run/reboot-required`** and **no `linux-image` in `apt list --upgradable`** before trusting it at scale.

## Cluster-stack failure modes (and their fixes)

These were found while hardening scale-up / scale-down / promote.

### 1. Self-fencing on join (stale fence map)

**Symptom.** Pacemaker fences healthy nodes right after they join.
**Cause.** The fence map (`pcmk_host_map`) accumulated stale instance IDs; a join made Pacemaker try to fence an instance that no longer existed.
**Fix.** The watcher rebuilds the entire fence map from scratch (querying EC2 for current instances) on every batch add and after ghost cleanup.

### 2. Ghost nodes block config sync

**Symptom.** `pcs cluster sync` blocks on unreachable nodes; new nodes can't join.
**Cause.** Terminated instances left entries in `corosync.conf`.
**Fix.** `cleanup_offline_nodes` removes stale entries from `corosync.conf`, clears the matching CIB entries, and prunes `lost` nodes from `crm_node -l`.

### 3. Split-brain on batch add

**Symptom.** Scaling to many nodes at once → readers form their own partition instead of joining the writer; the ring loses the token every ~25 s.
**Cause.** Distributing a full N-node config before nodes start let readers discover each other before the writer.
**Fix.** Add nodes **one at a time**; start the new node *before* reloading the writer's Corosync, so each node only ever learns about the already-running ring.

### 4. Node-ID reuse → stuck `S_PENDING`

**Symptom.** After a scale-down then scale-up, new readers join Corosync but Pacemaker is stuck in an election loop; DLM/GFS2 never start.
**Cause.** Corosync's `knet` caches `nodeid → IP` and won't update it for an existing ID on reload. Reusing a freed ID with a new IP creates a mismatch.
**Fix.** Assign monotonic node IDs from `/data/rocksdb/.next_nodeid`; never reuse. (See [Cluster Stack](04-cluster-stack.md#node-ids-why-they-never-repeat).)

### 5. Scale-up wedged by corosync runtime-nodelist drift (`CS_ERR_INVALID_PARAM`)

**Symptom.** After several scale cycles, a scale-up stops adding readers — they boot and tag `rocksdb-join` but never join; the watcher loops trying (and failing) to remove a terminated "ghost" node from `corosync.conf`.

**Cause.** Corosync's reload (`corosync-cfgtool -R`) can **grow** the runtime nodelist but **cannot shrink** it (a conf with fewer nodes than the runtime list is rejected with `CS_ERR_INVALID_PARAM`). So departed nodes accumulate as ghosts in the runtime nodelist across scale cycles. Once drift exists, removing a terminated node from conf also fails — it stays "stale", and the watcher's "don't add while stale" gate then blocks all new joins indefinitely.

**Fix (two parts).**
1. **Deadlock-breaker.** If a stale ghost has blocked joins for > `STALE_FORCE_SECS` (120 s) and readers are pending, the watcher adds them anyway. Safe because new node-IDs are always monotonically higher than anything in the runtime list, so *adding* always reloads cleanly — new readers join despite the ghost.
2. **Writer recycle resets the drift.** The runtime nodelist can only be truly cleared by restarting corosync; on the writer that means recycling it (terminate → ASG relaunches a fresh writer that remounts the data with `runtime = 1`). Recommended periodically for a heavily scale-cycled writer.

The drift's other (worse) consequence — ghosts inflating `expected_votes` and freezing DLM — is covered in issue 8 below: left unchecked it loses quorum and freezes I/O, so the fixes in issue 8 keep quorum correct despite the ghosts.

### 6. GFS2 journal-recovery timeout

**Symptom.** `gfs2fs` start times out during scale-up after a mass termination.
**Cause.** The default 2-minute resource timeout was too short to recover up to 15 journals at once.
**Fix.** GFS2 resource timeouts set to 300 s.

### 7. Lifecycle-hook deadlock

**Symptom.** Instances stuck in `Terminating:Wait`; scale operations blocked for minutes.
**Cause.** The ASG lifecycle hook required the writer's watcher to process each termination — which deadlocked if the writer itself was involved or during mass scale-down.
**Fix.** Removed the lifecycle hook entirely. Termination now relies on the per-node shutdown hook (`cluster-self-remove`) plus automatic GFS2 journal recovery for ungraceful exits. (See [Cluster Stack](04-cluster-stack.md#termination-handling--two-layers).)

### 8. Quorum loss freezes DLM/GFS2 (the silent writer wedge)

**Symptom.** A scale-down leaves the cluster looking fine — writer `/health` is `ok`, scaling works — but the **first real data-path operation hangs forever**. Classic trigger: a stress-test preload, whose first step (`systemctl stop rocksdb`) flushes/closes the DB and hangs; the `rocksdb_service` process is stuck in uninterruptible **D-state** (`STAT=Ds`, `WCHAN=dlm_lock`) and survives even SIGKILL. `corosync-quorumtool -s` shows `Quorate: No`, `Activity blocked`; `dlm_tool ls` shows the lockspace in **`kern_stop`**.

**Cause.** `votequorum` derives `expected_votes` from the configured node count. After a scale-down, ghost entries linger in `corosync.conf` (issue 5), so `expected_votes` stays inflated (e.g. conf=3 → `expected_votes=3`, `Quorum=2`) while only 1 node is live → **not quorate**. On quorum loss, `dlm_controld` enters `kern_stop` and stops granting GFS2 locks, so any DB I/O blocks in D-state. It's **silent** because scaling and `/health` never take a DLM lock — only the data path does (a write, or the preload's flush). This is why `1→16→1` cycles "work" but the next stress-test hangs.

**Fix (two complementary mechanisms — keep quorum correct despite ghosts).**
1. **Last Man Standing** — `last_man_standing: 1` is written into `corosync.conf` **before** `pcs cluster start` (it only engages on a fresh corosync start, not a reload). LMS lets votequorum lower `expected_votes` to the live members as the cluster shrinks *gradually* while staying quorate.
2. **Watcher pins `expected_votes` to the live member count at three points** — top of every main-loop iteration, **early inside scale-down cleanup** (right after departed nodes are killed from the ring, *before* the slow per-node conf-removal loop), and once at the end of cleanup. The value is **`Total votes` from `corosync-quorumtool -s`** (the node's current membership view), **not** the conf node count and **not** a grep of `corosync-quorumtool -l` (that grep can over-count lingering lines). The early-in-cleanup pin matters because the main-loop pin can't re-run while the watcher is inside the (minutes-long) cleanup of a `16→1` drop; without it `expected_votes` stays inflated for the whole cleanup window. Together these restore quorum through a **sudden** mass drop like `16→1` and stop a death spiral when the conf can't shrink (LMS alone can't step down through an instant loss of majority; the watcher sets the correct value directly).

**Verification.** After `16→1`, the writer settles `Quorate: Yes, expected_votes=1` (with `Flags: Quorate LastManStanding`), `dlm_tool status` shows `quorate 1` (not `kern_stop`), `rocksdb_service` stays in `Ssl` (not the unkillable `Ds`/`dlm_lock`), and the previously-hanging preload completes cleanly.

### 9. Substring IP match wedges a joining node

**Symptom.** During a scale-up (or after a kill), one new node never joins. Its `/health` is dead, it has **no `/etc/corosync/corosync.conf`**, `pcs cluster start` on it returns *"cluster is not currently configured on this node"*, and the writer's watcher loops on `Error connecting to <ip> - (HTTP error: 400)` forever. The rest of the cluster is fine.

**Cause.** The watcher decided whether a node was already a member with a **substring** grep:
```bash
grep -q "ring0_addr: ${IP}" /etc/corosync/corosync.conf   # BUG
```
`grep "ring0_addr: 10.0.0.20"` also matches the line `ring0_addr: 10.0.0.205`, because `10.0.0.20` is a string **prefix** of `10.0.0.205`. So when the cluster already contained a node whose IP had the new node's IP as a prefix, the new node was judged "already present" — never added to `corosync.conf`, never assigned a node ID, never sent a config. Its corosync therefore couldn't start.

It is **IP-dependent and intermittent** — it fires only when AWS hands the new node an IP that is a prefix of an existing node's IP. Observed collisions: `10.0.0.20`↔`10.0.0.205`, `10.0.0.22`↔`10.0.0.221`, `10.0.0.13`↔writer `10.0.0.133`. It has nothing to do with kills or concurrency — a back-to-back kill just happened to hand out a colliding IP. The same substring bug also existed in nodeid/status lookups, where it could resolve a *terminated* node to a *live* prefix-collision node's nodeid and `corosync-cfgtool -k` (kick) the wrong node.

**Fix (two layers).**
1. **Exact matching (the cure).** All membership and node-ID lookups now compare the full IP exactly (`... | awk '{print $2}' | grep -qxF "${IP}"`, and a `conf_nodeid_of_ip` helper using awk field-equality). A node is added unless its IP matches an existing entry *exactly*.
2. **Join watchdog (the backstop).** `reap_stuck_join_nodes` terminates any node stuck joining > 360 s so the ASG relaunches a clean one — this bounds the damage of *any* future join failure even if a new edge case appears. (See [Cluster Stack](04-cluster-stack.md#join-watchdog-reap_stuck_join_nodes).)
3. **Liveness guard.** Removal paths now skip any node whose EC2 instance is still running (`instance_running_by_ip`), so a live joining node can never be evicted by a stale ASG snapshot.

**Verification.** A clean full run after the fix completed `3→16` and a deliberate `kill 2 readers back-to-back` with no wedge.

### 10. Fence storm on large bulk scale-down (intermittent)

**Symptom.** A big scale-down (e.g. `16→5` or `16→1`) sometimes leaves the cluster below target — a *surviving* node gets fenced/rebooted and the cluster churns instead of settling at the target size. **Intermittent**: the same operation succeeds cleanly on another run.

**Cause.** Terminating many nodes at once triggers heavy simultaneous recovery on the survivors — Corosync ring re-formation plus DLM/GFS2 recovery of every departed node's locks and journals. Under that load a surviving node can miss the Corosync token and be briefly declared lost; Pacemaker then queues a stonith reboot (DLM monitor `on-fail=fence`), which executes even though the node has rejoined. It's a load-induced **false-positive fence**, so it's probabilistic and scales with the number of nodes removed at once. Small removals (kill 1–2, scale by a few) almost never trigger it.

**Mitigations.**
- ✅ **More token tolerance (DONE).** The Corosync `token` was raised from `10000ms` to **`30000ms`** (see [Cluster Stack](04-cluster-stack.md#corosync--membership-and-messaging)). The larger token gives a busy-but-alive node far more slack during recovery bursts, so it reduces this false-fence risk as well as fixing token loss on scale-up (issue 11 below). Trade-off: slower genuine-failure detection (~30 s vs ~10 s), acceptable because fencing + GFS2 journal recovery dominate recovery time anyway.
- **Stepped scale-down** — remove only a few nodes per step and let the cluster re-stabilise between steps, keeping each step's recovery load small. Still the safest approach for very large reductions.

DLM fencing itself **cannot** be relaxed — it is what prevents split-brain corruption on the shared volume. The cluster self-heals (the fenced node's ASG replacement rejoins), but it's disruptive; **prefer stepped scale-down for large reductions.**

### 11. Corosync token loss at scale → reload hangs / quorum collapse / DLM freeze (during scale-up)

**Symptom.** A scale-up toward 16 nodes stalls badly: `corosync-cfgtool -R` reloads hang for **12–26 minutes**, the ring re-forms constantly, and the writer logs `Token has not been received in 11401 ms / 25955 ms`. In the worst case quorum collapses → `dlm_controld` enters `kern_stop` → GFS2 freezes (the no-quorum freeze, same wedge as issue 8).

**Cause.** The base Corosync `token` was **10000 ms**. Corosync's *effective* token grows with the node count (`base + (N-2)×~650 ms`), so at 16 nodes a 10 s base gave only ~19 s effective. Under load — readers doing their initial RocksDB secondary catch-up after a preload — that wasn't enough, and the token was lost repeatedly (~26 s stalls observed). Each loss re-formed the ring and made reloads hang, stalling scale-up; when it cascaded into quorum loss, DLM `kern_stop` froze all GFS2 I/O.

**Fix.** Raise the base `token` to **30000 ms** (set in `rocksdb_stack.py` writer userdata, `scripts/setup_cluster.sh`, and the `scripts/rocksdb_service.cc` bootstrap). That gives ~39 s effective at 16 nodes, comfortably above the observed ~26 s stalls. After the fix: **zero token-loss events** at 16 nodes, reloads no longer hang, and scale-up is reliable (full 1→16 in ~14 min end-to-end). The cluster reaches and holds `Quorate: Yes` with 16/16 votes. (For very large 1–2 TB preloads consider `token=40000`.) Trade-off: slower ungraceful-failure detection (~30 s vs ~10 s) — acceptable, as fencing + GFS2 journal recovery dominate recovery time.

**Manual recovery (if a cluster is already wedged on an old token value).**
- Pin `expected_votes` to the live count to restore quorum immediately: `corosync-quorumtool -e <live_node_count>` on the writer (the watcher does this automatically every loop — see issue 8).
- Or **recycle the writer** (terminate it; the ASG relaunches a fresh one that remounts the data with clean corosync state and the corrected token).

## Known operational gotchas

### `scan`/`read` failed with "Invalid control character" on binary values

**Symptom.** A `scan` (or `read` of a specific key) returned a client-side JSON parse error like `Invalid control character at: line 1 column 87 (char 86)`, even though the node was healthy and other keys read back fine.

**Cause.** The service's JSON string escaper only escaped `"`, `\`, and `\n`. JSON requires **all** control characters (U+0000–U+001F) to be escaped, so a stored key/value containing a raw `\r`, `\t`, NUL, or other control byte (common with stress-test/binary data) produced invalid JSON. A single such record broke the whole `scan` response; a targeted `read` of a clean key still worked, which is why it looked intermittent.

**Fix.** `esc()` in `rocksdb_service.cc` now emits the short escapes (`\b \f \n \r \t`) and `\u00XX` for any other control byte, and iterates as `unsigned char` so high bytes (≥ 0x80, valid UTF-8/binary) pass through unchanged. Requires an AMI rebuild (or recompiling `rocksdb_service` on the nodes) to take effect.

### EBS attach race on replacement

When a node is killed and the ASG launches a replacement, the new instance may fail to attach the volume because the old attachment takes 30–60 s to release. The boot script retries (up to 30×) and usually wins on a later attempt. If it persists, detach the volume from the terminated instance in the console.

### VPC won't delete after stress tests

A leftover `rocksdb-loader-sg` security group can block VPC deletion. Delete it and re-run `destroy.sh`.

## Recovery procedures

### Rebuild a degraded cluster (data preserved)

`setup_cluster.sh` now runs over SSM — invoke it **locally on the writer** via SSM Session Manager (or Run Command). The `KEY_PATH` argument has been removed; usage is now `setup_cluster.sh <WRITER_IP_or_INSTANCE_ID> <VOLUME_ID>`:

```bash
aws ssm start-session --target <WRITER_INSTANCE_ID>
sudo /usr/local/bin/setup_cluster.sh <WRITER_IP_or_INSTANCE_ID> <VOLUME_ID>
```

Force-stops all cluster services, recreates the Pacemaker cluster, reconfigures fencing/DLM/GFS2, and restarts. Data on the EBS volume is untouched.

### Writer down → promote a reader

```bash
# TUI:  promote <node_id>
./scripts/promote_reader.sh <READER_IP>
```

`promote_reader.sh <READER_IP>` is still the entry point; it now drives the nodes over **SSM** internally (no SSH). The promote path removes a stale RocksDB `LOCK` automatically. By hand on the new writer (over SSM, only when certain the old writer is dead):

```bash
aws ssm start-session --target <NEW_WRITER_INSTANCE_ID>
sudo rm /data/rocksdb/db/LOCK && sudo systemctl restart rocksdb.service
```

### Useful inspection commands

Reach any node with **SSM Session Manager** (`aws ssm start-session --target <INSTANCE_ID>`) — there is no public SSH. Then run, on the node:

```bash
# Cluster status (any node)
sudo pcs status

# Corosync node IDs / IPs
grep -E 'ring0_addr|nodeid' /etc/corosync/corosync.conf

# Writer-side watcher logs
sudo journalctl -u cluster-watcher.service --no-pager -n 50

# RocksDB service logs
sudo journalctl -u rocksdb.service --no-pager -n 30

# Instance boot log (role election, volume attach)
sudo cat /var/log/rocksdb-userdata.log

# Corosync membership events (diagnosing churn)
sudo journalctl -u corosync --no-pager --since "-15min" | grep -iE "membership|left|joined|token"
```

> The architectural limits and trade-offs (16-node ceiling, single AZ, single volume, single writer, shared IOPS) are covered in [Overview → When to use this](01-overview.md#when-to-use-this-and-when-not-to).

---
Next: [API Reference →](12-api-reference.md)
