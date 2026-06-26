[← The TUI](08-tui.md) · [Home](../README.md) · [Stress Testing →](10-stress-testing.md)

# 9. Testing

This chapter covers **functional / correctness testing** — does every operation behave correctly, and does the cluster stay healthy through scaling, failover, and failures. Performance testing is separate ([Stress Testing](10-stress-testing.md)).

## Testing philosophy

The guiding principle: **the tests must do exactly what the TUI does.** The TUI is the real interface an operator uses, so a test is only meaningful if it exercises the same AWS calls and REST endpoints. Earlier test scripts had drifted from the TUI (hardcoded sizes, extra data assertions, and a "promote" that *terminated* the writer rather than demoting it gracefully). The harness was reworked so every test funnels through TUI-accurate building blocks.

## What "healthy" means (the readiness definition)

Almost every test waits for the cluster to be *ready* at some size `N`. Readiness is defined to match what the TUI shows, and all three conditions must hold for two consecutive polls:

1. **ASG `InService == N`** — AWS considers exactly `N` instances in service.
2. **Writer `/cluster/nodes` `online == N`** — Corosync sees exactly `N` members.
3. **Every InService node's `/health` is `ok`** — each RocksDB service is up and serving.

This is implemented once in `test/common.sh::wait_for_cluster_nodes` and reused everywhere. Requiring all three (not just one) is what catches partial failures — e.g. a node that is InService in AWS but never joined Corosync, or joined but whose service is unhealthy.

## The test harness

The harness lives in `test/` and is intentionally small — **one script per TUI command**, plus shared helpers and an orchestrator. Like the TUI, it drives nodes over **SSM Run Command** to `http://localhost:8080` (port 8080 isn't publicly reachable). Node-specific reads/scans target the instance **by instance-id over SSM**; writes and admin actions also go via SSM, with admin requests supplying the on-box bearer token read from the node's `/etc/rocksdb/service.env`. No SSH is used.

| File | Mirrors TUI command | What it does |
|---|---|---|
| `common.sh` | — | Shared helpers: stack/instance discovery, `wait_for_cluster_nodes` (readiness), `resolve_node` (node-id/IP resolution, like the TUI), assertions. |
| `scale.sh <N>` | `scale` | Sets ASG desired capacity, waits for readiness at `N`. |
| `promote.sh [ip]` | `promote` | Graceful promote via `promote_reader.sh` (old writer demoted in place), waits for readiness. |
| `kill.sh <node>` | `kill` | Resolves and terminates a node, then waits for the cluster to **auto-recover** to its current size. |
| `write.sh <k> <v>` | `write` | `POST /put` to the writer. |
| `read.sh <node> <k> [expected\|ABSENT]` | `read` | `GET /get` from a node; optionally asserts the value, or asserts the key is gone. |
| `scan.sh <node> [min]` | `scan` | `GET /scan` from a node; optionally asserts a minimum record count. |
| `delete.sh <k>` | `delete` | `POST /delete` to the writer. |
| `run_custom_sequence.sh` | — | Orchestrator that strings the above into one end-to-end run. |

Each command script also makes a good **manual tool**, e.g. `bash test/read.sh 6 user:1 Alice`.

Older/ancillary scripts (the previous numbered suite, the Python TUI test, lifecycle helpers) were moved to `test/archive/` to keep one clear, current set. Lifecycle (build/deploy/destroy) is handled by the repo-root `scripts/build_ami.sh`, `deploy.sh`, and `destroy.sh`.

## What's covered

The orchestrator (`run_custom_sequence.sh`) exercises **all seven TUI commands** plus failover and recovery in one run:

```
recycle the fleet onto the current AMI (size 1)
write k1, k2        →  read k1 from the writer     →  scan the writer (>= 2 records)
scale 1 → 8         →  read k1 from a reader        →  scan a reader   (replication check)
scale 8 → 3
promote a reader → writer
write k3 (new writer) →  read k3 from a reader
kill a reader      →  cluster auto-recovers to 3
delete k1          →  read k1 → expect ABSENT
scale 3 → 16
kill 2 readers back-to-back →  cluster auto-recovers to 16   (race regression)
scale 16 → 5
```

| Capability | How it's verified |
|---|---|
| **scale** (up & down, small & max) | `scale.sh` to 8, 3, 16, 5; readiness asserted each time. |
| **promote** (failover) | `promote.sh`; new writer must reach `readwrite` and the cluster return to full readiness. |
| **kill** (resilience) | `kill.sh`; cluster must auto-recover to size with a fresh replacement. |
| **kill 2 back-to-back** (regression) | Terminate two readers in one call; cluster must recover to 16 with no wedged node. Guards against the substring-IP-match bug (see [Troubleshooting](11-troubleshooting.md#9-substring-ip-match-wedges-a-joining-node)). |
| **write / delete** | `write.sh` / `delete.sh` to the writer; `403` enforced on readers. |
| **read / scan** | `read.sh` / `scan.sh` against the writer *and* a reader. |
| **replication / freshness** | Read the same key from a reader after writing it to the writer. |
| **deletion** | `read.sh … ABSENT` confirms a deleted key is actually gone. |
| **node resolution** | `read.sh` exercised by both public IP and Corosync node ID. |

## How a run is driven

Because a full scale cycle takes ~40 minutes, runs are launched as a background process and monitored, with output tee'd to a log:

```bash
bash test/run_custom_sequence.sh 2>&1 | tee /tmp/rocksdb_custom_run.log
```

Each step prints timestamps and a `PASS`/`FAIL`, and the readiness waiter prints live progress like:

```
... InService=16/16 online=12/16 svc_ok=12/16
```

which makes it obvious whether nodes are joining steadily (good) or flapping (a problem to investigate). At the end the harness prints a **per-step duration summary**, which is the source of the timings in [Operations](07-operations.md#how-long-things-take).

## The most recent run

The latest clean full run passed every step on the fixed AMI — including the two steps that previously failed:

| Step | Result | Duration |
|---|---|---|
| Recycle onto the fixed AMI | ✅ | ~6 min (normal) |
| Scale 1 → 8 | ✅ | 7:04 |
| Scale 8 → 3 | ✅ | 6:24 |
| Promote reader → writer (graceful) | ✅ | 1:36 |
| Kill 1 reader → recover to 3 | ✅ | 4:27 |
| Scale 3 → 16 | ✅ no wedge | 16:44 |
| **Kill 2 readers back-to-back → recover to 16** | ✅ no wedge | 6:39 |
| Scale 16 → 5 | ✅ | 6:20 |
| write/read/scan/delete (incl. replication, `ABSENT`, node-ID resolution) | ✅ | <10 s each |

Two real bugs were found and fixed through this testing — surprise auto-reboots causing churn (`Run 1`), and a substring IP-match wedging a joining node (`Run 2`). Both are written up in [Troubleshooting](11-troubleshooting.md).

## A real bug this caught: surprise reboots = membership churn

During scaling, fresh readers appeared to "fail, then rejoin." Investigation (no fencing events, no token loss, clean departures) showed the readers were **rebooting themselves** shortly after joining: `unattended-upgrades` installed a newer kernel on first boot and triggered an automatic OS reboot. Each reboot made the node leave and rejoin the Corosync ring — the churn.

The fix (in `setup_phase2.sh`, baked into the AMI): mask the `apt-daily` timers and `unattended-upgrades`, and disable automatic reboots. After rebuilding the AMI and re-running the full sequence, the churn was gone. Full write-up in [Troubleshooting](11-troubleshooting.md).

---
Next: [Stress Testing →](10-stress-testing.md)
