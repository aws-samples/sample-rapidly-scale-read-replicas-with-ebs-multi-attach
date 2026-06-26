[← Storage Layer](03-storage-layer.md) · [Home](../README.md) · [RocksDB & Service →](05-rocksdb-service.md)

# 4. Cluster Stack — keeping the shared disk safe

GFS2 cannot run alone. It needs a cluster underneath it that answers three questions at all times:

1. **Who is in the cluster right now?** (membership)
2. **Where should the shared resources run?** (resource management)
3. **How do we guarantee a broken node can't corrupt the shared disk?** (fencing + locking)

Four pieces of software answer these. Removing any one breaks GFS2.

```
Corosync   → membership & messaging   (who is in the ring)
Pacemaker  → resource manager         (start DLM & GFS2 in the right order/place)
DLM        → distributed locks        (coherent metadata across nodes)
fence_aws  → STONITH                  (kill a bad node via the EC2 API)
```

## The component versions (Ubuntu 24.04)

Ubuntu 24.04 was chosen because it's the only distribution that ships all of these in its default repositories at compatible versions.

| Component | Package | Version |
|---|---|---|
| Corosync | `corosync` | 3.1.7 |
| Pacemaker | `pacemaker` | 2.1.6 |
| pcs (management CLI) | `pcs` | 0.11.x |
| DLM | `dlm-controld` | 4.2.0 |
| GFS2 tools | `gfs2-utils` | 3.5.1 |
| Fence agents | `fence-agents-aws` | 4.12.1 |

> Only the AWS-specific fence agent is installed (`fence-agents-aws`), not the full `fence-agents` meta-package. The fleet only ever fences via `fence_aws`, so pulling the AWS agent alone avoids dragging in every other cloud's agents (and their large Azure/GCP Python SDK dependencies) — a leaner, faster AMI build.

---

## Corosync — membership and messaging

Corosync is the heartbeat layer. It runs on every node and maintains the **membership ring**: the authoritative list of which nodes are currently alive and connected.

- It uses the **Totem protocol** — a token is passed around the ring; a node that fails to pass the token within the timeout is declared gone, and a new membership is formed.
- It provides reliable, ordered messaging that DLM and Pacemaker build on.
- Its config, `/etc/corosync/corosync.conf`, lists every node with its IP (`ring0_addr`) and a numeric `nodeid`.
- **Token timeout is set to 30 s** (`token: 30000`, the base value). This was raised from 10 s after token loss at scale repeatedly broke scale-up. Corosync's *effective* token at N nodes is roughly `base + (N-2)×~650 ms`, so at 16 nodes a 10 s base gave only ~19 s effective. Under load — readers doing their initial RocksDB secondary catch-up after a preload — the token was lost repeatedly (`Token has not been received in 11401 ms / 25955 ms`), causing constant ring re-formation: `corosync-cfgtool -R` reloads hung for 12–26 minutes and stalled scale-up, and in the worst case quorum collapsed → DLM `kern_stop` → GFS2 froze. A 30 s base gives ~39 s effective at 16 nodes, comfortably above the observed ~26 s stalls; token loss dropped to zero and scale-up became reliable. **Trade-off:** ungraceful-failure detection is correspondingly slower (~30 s vs ~10 s), which is acceptable because fencing + GFS2 journal recovery dominate recovery time anyway. (For very large 1–2 TB preloads consider `token=40000`.)

When membership changes (a node joins or leaves), Corosync fires an event that DLM and Pacemaker react to.

> A practical consequence: anything that makes a node leave/rejoin the ring (e.g. an unexpected reboot) shows up as membership churn. This is exactly the symptom that the unattended-upgrades auto-reboot bug caused — see [Troubleshooting](11-troubleshooting.md).

## Pacemaker — the resource manager

Pacemaker decides **what runs where** and keeps it running. Here it manages a small set of resources, all as **clones** (a clone = "run this on every node"):

| Resource | Type | Meaning |
|---|---|---|
| `clusterfence` | `stonith:fence_aws` | The fencing agent (one, active on the current DC). |
| `dlm` (clone) | `ocf:pacemaker:controld` | DLM lock manager on every node. |
| `gfs2fs` (clone) | `ocf:heartbeat:Filesystem` | The GFS2 mount on every node. |

Pacemaker enforces **ordering**: `dlm-clone` must start before `gfs2fs-clone` (you can't mount GFS2 before its lock manager exists). It also monitors each resource and, on failure, will fence the node (`on-fail=fence`).

Two Pacemaker properties are deliberately set:

| Property | Value | Why |
|---|---|---|
| `stonith-enabled` | `true` | DLM **refuses to start without fencing**. Non-negotiable for a shared disk. |
| `no-quorum-policy` | `freeze` | If quorum is lost, **freeze** resources in place (don't let a minority partition act independently on the shared disk). Two mechanisms keep the live set quorate during scaling so this never trips falsely: **Last Man Standing** (`last_man_standing` in corosync.conf) lowers `expected_votes` as the cluster shrinks gradually, and the watcher **pins `expected_votes` to the live member count** (`Total votes` from `corosync-quorumtool -s`) on every loop iteration (handles sudden mass drops like `16→1` that LMS can't step through). Together they stop leftover ghosts in `corosync.conf` from inflating the quorum requirement. |

## DLM — the Distributed Lock Manager

DLM is a kernel-level lock coordinator, run as a Pacemaker clone on every node. GFS2 calls into it for **every metadata operation**. When a node joins or leaves, DLM redistributes lock ownership — a recovery window of roughly 10 s. Without DLM, GFS2 cannot mount in cluster mode. (DLM's role in coherence is shown in [Storage Layer](03-storage-layer.md#how-gfs2-stays-coherent-the-dlm).)

## Fencing — `fence_aws` (STONITH)

**Fencing** is how the cluster guarantees a suspect node is truly dead before its resources are recovered elsewhere — so it cannot wake up and scribble on the shared disk. The acronym is STONITH: "Shoot The Other Node In The Head."

On AWS, "shooting" a node means calling the EC2 API to stop/terminate it. The `fence_aws` agent does this. It's configured with a **host map** translating each node's private IP to its EC2 instance ID:

```
pcmk_host_map = "10.0.0.10:i-0abc...;10.0.0.11:i-0def...;..."
```

### Why fencing is mandatory here

EBS Multi-Attach gives every node write access to the same blocks and provides **no** I/O fencing of its own. The cluster software is the *only* thing preventing a confused node from corrupting the shared filesystem. That's why DLM won't even start unless `stonith-enabled=true`.

### The fence_aws wrapper

Stock `fence_aws` has a sharp edge: if asked to fence an instance that AWS has **already terminated**, it errors out — and a failed fence makes DLM block **forever** (it can't confirm the node is dead). Since instances here are often already gone (ASG scale-in, kills), `fence_aws` is wrapped (`scripts/fence_aws_wrapper.sh`):

- For a `status` check on an instance that is `terminated`/`shutting-down`, it reports the node as already off (exit code 2) instead of failing.
- For a fence (`off`/`reboot`) on an already-dead instance, it reports success (exit 0).
- For everything else, it passes through to the real `fence_aws`.

This turns "the node is already dead" from a hang into an instant success, which is what lets DLM and GFS2 recover quickly after terminations.

---

## Node IDs — why they never repeat

Each node has a Corosync `nodeid`. This system assigns them from a **monotonic counter that only ever increases** — IDs are *never reused*, even after a node is removed.

The counter is a single file on the shared GFS2 volume: `/data/rocksdb/.next_nodeid`.

- Initialized to `2` when the writer first formats GFS2 (the writer itself is node `1`).
- Incremented by the cluster watcher every time a node is added.
- Never decremented.

```
Start:     node 1 (writer)
Scale +3:  nodes 1, 2, 3, 4
Scale -2:  nodes 1, 4            (2 and 3 removed)
Scale +2:  nodes 1, 4, 5, 6      (NOT 2, 3 — IDs never reused)
```

### Why reuse would break things

Corosync's `knet` transport caches the `nodeid → IP` mapping at startup and does **not** update it for an existing ID on a config reload — it only processes additions and removals. If a freed ID (say `2`) is reused for a different IP, Pacemaker sees the new IP while Corosync still maps ID `2` to the old IP. The new node's Pacemaker controller then gets stuck in an election loop (`S_ELECTION → S_PENDING`) and never becomes usable.

This is a real Corosync behavior ([issue #234](https://github.com/corosync/corosync/issues/234), present through 3.1.x). Monotonic IDs sidestep it entirely.

---

## The Cluster Watcher

`cluster_watcher.sh` runs as a systemd service **on the writer only**. It is the automation that makes scaling hands-off: it continuously reconciles the *actual* cluster membership with the *desired* fleet (the ASG). It loops every 5 seconds:

```
every 5s on the writer:
  ensure_pcsd_auth        # make sure we can talk to peer nodes
  pin_expected_votes      # set expected_votes = live Total votes (keeps quorum correct vs conf ghosts)
  proactive_fence_ack     # unblock DLM for nodes that already left the ring
  cleanup_offline_nodes   # remove terminated nodes from corosync.conf + CIB; rebuild fence map; re-pin votes
  recover_offline_asg_nodes  # restart cluster on nodes that are in the ASG but offline
  reap_stuck_join_nodes   # watchdog: terminate nodes stuck joining too long
  add_new_nodes           # find instances tagged rocksdb-join and add them to the cluster
```

`pin_expected_votes` reads the live member count from `corosync-quorumtool -s` (`Total votes`) and, if `expected_votes` differs, sets it with `corosync-quorumtool -e <live>`. It runs first thing every loop, and again early inside `cleanup_offline_nodes`, so quorum tracks the live set even when ghosts linger in `corosync.conf` (see [Runtime-nodelist drift](#runtime-nodelist-drift-and-the-scale-up-deadlock-breaker) below).

### Adding a node (`add_new_nodes`)

When a new reader boots it tags itself `rocksdb-join=rocksdb-cluster`. The watcher:

1. Finds instances with that tag that aren't already Online.
2. Checks — with an **exact** IP match — whether the node is already in `corosync.conf`; if not, assigns it a fresh monotonic node ID from the counter file and adds it.
3. Syncs the config, **starts the node first**, then reloads the writer's Corosync (`corosync-cfgtool -R`) — order matters, so the writer doesn't probe a not-yet-running node and disrupt the ring.
4. Waits for the node to come Online and its RocksDB service to report healthy, then removes the join tag.
5. Rebuilds the fence map for the full membership.

Two correctness rules in this path were hard-won:
- **Exact IP matching everywhere.** Membership and node-ID lookups compare the full IP, never a substring. A substring check (`grep "ring0_addr: 10.0.0.20"`) wrongly matches `10.0.0.205`, so a new node whose IP is a prefix of an existing node's IP was judged "already present", never added, and wedged with no config. (See [Troubleshooting](11-troubleshooting.md#9-substring-ip-match-wedges-a-joining-node).)
- **One node at a time.** Batch-adding caused split-brain and token storms (see [Troubleshooting](11-troubleshooting.md)).
- **Ghost-tolerant joins.** Before adding, `add_new_nodes` calls `prune_dead_conf_nodes` to strip any `corosync.conf` node-block whose EC2 instance is no longer running (a fast direct file edit, guarded by the authoritative `instance_running_by_ip` check; it never touches the writer or a running/joining node). Without this, a conf still carrying ghosts from a previous scale-down makes a joining reader's corosync fail to start (it's handed dead peer IPs → `HTTP 400`) and makes `pcs cluster sync` block waiting on an unreachable ghost. This is what keeps **rapid scale cycling** from wedging scale-up, and it's why the slower `cleanup_offline_nodes` no longer needs to "keep up" for correctness.

### Join watchdog (`reap_stuck_join_nodes`)

A backstop so a node can never stay stuck joining forever. Every loop it records, on the shared volume (`/data/rocksdb/.join_watch/<ip>`), when each `rocksdb-join`-tagged node was first seen pending. If a node has been pending **longer than 360 s** without coming Online, the watcher **terminates it** — the ASG then launches a clean replacement that joins from scratch. This bounds recovery time even for an unforeseen edge case, leaning on the system's core principle that nodes are disposable.

### Removing a node (`cleanup_offline_nodes`)

When a node is no longer InService in the ASG, the watcher fences/acks it, kills it from the Corosync runtime ring, removes it from `corosync.conf`, cleans Pacemaker's CIB and `crm_node` history, and rebuilds the fence map. Key safety behaviors:
- It **never removes a node whose EC2 instance is still running** — an authoritative per-IP `ec2 describe-instances` check (`instance_running_by_ip`) guards every removal, so a live node that is briefly missing from a single ASG snapshot (e.g. during rapid churn) is never mistakenly evicted.
- It **re-pins `expected_votes` early** (right after the departed nodes are killed from the ring, before the slow per-node conf-removal loop), so quorum stays correct for the whole multi-minute cleanup of a large scale-down rather than only at the end (see [Runtime-nodelist drift](#runtime-nodelist-drift-and-the-scale-up-deadlock-breaker)).

### Runtime-nodelist drift, and the scale-up deadlock-breaker

Corosync keeps two views of the node set: the static `corosync.conf` nodelist, and an in-memory **runtime nodelist** updated by reload (`corosync-cfgtool -R`). A reload can *grow* the runtime nodelist (add a node) but **cannot shrink it** — corosync rejects a reload whose conf has fewer nodes than the runtime list (`CS_ERR_INVALID_PARAM`). So on scale-down, even after a node is removed from `corosync.conf`, its entry **lingers in the runtime nodelist as a ghost**, and these accumulate across scale cycles (e.g. each `1→16→1` leaves ~15).

This drift has **two consequences, and both are now defended against:**

**1. It can freeze the cluster via quorum loss (the dangerous one).** corosync's `votequorum` derives `expected_votes` from the configured node count. If ghosts linger in `corosync.conf`, `expected_votes` is inflated above the live node count — so after a scale-down (e.g. `16→1` with ghosts left in conf), the live nodes can't meet quorum. When a node loses quorum, **`dlm_controld` enters `kern_stop` and freezes all GFS2 lock operations.** Any process doing DB I/O then blocks in uninterruptible `dlm_lock` D-state (unkillable — survives SIGKILL), wedging the writer. This is silent until something exercises the data path: scaling and `/health` don't take DLM locks, so the cluster *looks* fine, but the first real write or a stress-test preload (which stops rocksdb → flushes the DB) hangs forever. **Two fixes keep quorum correct despite ghosts:**
   - **Last Man Standing** (`last_man_standing: 1` in `corosync.conf`, set at cluster setup) lets votequorum lower `expected_votes` to the live members as the cluster shrinks gradually.
   - The **watcher pins `expected_votes` to the live member count** (`corosync-quorumtool -e <live>`, where `<live>` is **`Total votes` from `corosync-quorumtool -s`** — the node's current membership view — not the conf count and not a grep of `-l`). The pin runs at **three points**: the top of every main-loop iteration; **early inside the scale-down cleanup** (right after departed nodes are killed from the ring, before the slow per-node conf-removal loop, which can run for minutes on a `16→1`); and once more at the end of cleanup. Pinning early-in-cleanup matters because the main-loop pin can't re-run while the watcher is inside the (slow) cleanup function. This reliably restores quorum through a *sudden* mass drop like `16→1` (LMS alone can't step down through an instant loss of majority) and prevents a death spiral when the conf can't shrink. Verified: after `16→1`, the writer settles `Quorate: Yes, expected_votes=1` with DLM `quorate 1`, and the previously-hanging preload (`systemctl stop rocksdb`) runs cleanly.

**2. It can block scale-up (the deadlock).** If a *terminated* node's entry can't be removed from `corosync.conf` (the shrink-reload fails once drift exists), it stays "stale". Two mechanisms keep this from blocking joins:
   - **Ghost prune before every add.** `add_new_nodes` first runs `prune_dead_conf_nodes`, removing conf node-blocks whose instance is gone, so joiners always get a clean conf (no `HTTP 400` from dead peer IPs, no `pcs cluster sync` hang on an unreachable ghost). This is the primary defense and is what makes back-to-back `1↔16` cycling safe — validated across 4 rapid cycles with conf returning to exactly 1/16 each leg and no accumulation.
   - **Deadlock-breaker.** Independently, the watcher's rule of "don't add new nodes while a stale node is present" is bounded: if a stale ghost has blocked joins for longer than `STALE_FORCE_SECS` (120 s) and readers are waiting, it adds them anyway (safe, because new node-IDs are monotonically higher than anything in the runtime list, so *adding* always reloads cleanly).

The only way to truly *reset* the runtime nodelist is to restart corosync — which on the writer means a **recycle**: terminate the writer, and the ASG relaunches a fresh one that remounts the data with a clean (`runtime = 1`) corosync. With the two quorum fixes above the drift no longer freezes anything, but a periodic recycle is still the way to clear accumulated ghosts on a long-lived, heavily scale-cycled writer.

---

## Termination handling — two layers

There is **no ASG lifecycle hook** (it was removed — it caused deadlocks where terminations waited on the writer and stuck for minutes). Instead, clean departure is handled two ways:

### Layer 1 — graceful shutdown hook

`cluster-self-remove.service` runs on **every node** at shutdown (`cluster_self_remove.sh`):

1. Stops `rocksdb.service` (releasing the RocksDB `LOCK`).
2. Runs `pcs cluster stop --force` to unmount GFS2 and release DLM locks — with a 15 s timeout.
3. If that hangs (DLM busy recovering another node), it force-kills Corosync/Pacemaker so the survivors detect the departure via token timeout.

This fires for any normal termination (ASG scale-in, `terminate-instances`, console terminate) — anything that sends an ACPI shutdown signal.

### Layer 2 — automatic recovery (ungraceful)

If a node vanishes without running the hook (hardware failure, abrupt termination):

1. Corosync notices the missing token (~30 s at 16 nodes) and re-forms membership.
2. Pacemaker fences the node via `fence_aws` (the wrapper makes this instant if it's already terminated).
3. GFS2 **replays the dead node's journal** automatically (10–30 s) to restore consistency.
4. The cluster watcher purges the stale entry from `corosync.conf`.

GFS2's per-node journals (16 pre-allocated) are exactly what makes ungraceful loss recoverable. The GFS2 resource timeout is 300 s so even a mass termination (up to 15 journals at once) can be recovered.

---

## Auth keys and how readers join securely

Corosync and Pacemaker authenticate peers with shared secret keys (`/etc/corosync/authkey`, `/etc/pacemaker/authkey`). The writer generates these when it first sets up the cluster and stores them in SSM (SecureString). New readers fetch them on boot to join. A small timer service (`cluster-key-sync.timer`, readers only) re-checks SSM every 10 s and updates local keys if they change — so a rebuilt cluster can re-key readers without redeploying.

## Bootstrapping the cluster

The very first node runs the single-node setup inline in its boot script (see [Components](06-components.md)). For recovery — if the whole cluster gets into a bad state — `scripts/setup_cluster.sh` rebuilds it from scratch across all currently-attached instances (force-stop everything, re-create the cluster, re-add fencing/DLM/GFS2, preserve the data on the volume). It is safe to re-run.

### Enabling Last Man Standing at setup (implementation detail)

Both the inline boot setup (`rocksdb_stack.py` UserData) and `scripts/setup_cluster.sh` enable Last Man Standing by **directly editing `corosync.conf` between `pcs cluster setup` and `pcs cluster start`**:

```bash
pcs cluster setup ${CLUSTER_NAME} ${PRIV_IPS} --force
# Insert LMS into the votequorum block BEFORE the first start
sed -i '/provider: corosync_votequorum/a\        last_man_standing: 1\n        last_man_standing_window: 10000' /etc/corosync/corosync.conf
pcs cluster start --all   # (or `start` for the single first node)
```

Two reasons it is done this way, by direct conf edit before the first start:
- **LMS only engages on a *fresh* corosync start.** Adding it to a running cluster via a reload just loads the value into config without activating the behavior, so it must be present before `pcs cluster start`.
- **`pcs quorum update` proved unreliable** here (the setting was silently dropped/clobbered on later config syncs). A direct conf edit is deterministic and survives subsequent `pcs` operations.

`last_man_standing_window: 10000` (10 s) is the interval over which votequorum recalculates `expected_votes` down to the surviving members as nodes leave *gradually*. LMS cannot step through a *sudden* loss of majority (e.g. `16→1`) — that case is covered by the watcher's `pin_expected_votes` (see [The Cluster Watcher](#the-cluster-watcher)). A healthy writer shows `Flags: Quorate LastManStanding` in `corosync-quorumtool -s`.

---
Next: [RocksDB & the REST Service →](05-rocksdb-service.md)
