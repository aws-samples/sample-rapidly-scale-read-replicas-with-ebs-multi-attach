# Rapidly Scale Read Replicas with EBS Multi-Attach

A reusable blueprint for **read scale-out without copying data**: keep one physical copy of your dataset on a single EBS Multi-Attach volume, mount it coherently on up to 16 EC2 instances with a cluster filesystem, and fan reads across the fleet behind a load balancer. A new read replica is serving in minutes — no replication stream, no sharding, no second copy — whatever the dataset size.

**RocksDB is the worked example here** (its read-only *secondary* mode is a clean fit), but the pattern is engine-agnostic: the storage, cluster-filesystem, fencing, and scaling automation are reusable, and adapting it to another store is mostly about how that engine opens the shared files read-only. See [Generalizing beyond RocksDB](#generalizing-beyond-rocksdb).

This documentation explains the solution, the problem it solves, how every piece works, how to operate it, and how it was tested.

> **Status: proof of concept.** This is a working PoC that demonstrates the pattern end-to-end — built, deployed, scale-tested (1↔16), and stress-tested on AWS. It is **not production-hardened**: it runs in a single AZ on one shared volume with one writer, the data plane is unauthenticated and plaintext-HTTP, and there are no backups. See [Security](docs/13-security.md) and [When to use this](docs/01-overview.md#when-to-use-this-and-when-not-to) for the accepted trade-offs and what to close before production use.

## Watch the walkthrough

A narrated tour of the problem, the architecture, and the live numbers (~5 min):

https://github.com/aws-samples/sample-rapidly-scale-read-replicas-with-ebs-multi-attach/raw/main/presentation.mp4

<sub>If the player doesn't load, [download/view <code>presentation.mp4</code> directly](presentation.mp4).</sub>

---

## What this is, in 30 seconds

The pattern: keep **one physical copy** of your data on a single AWS EBS io2 volume, attach that volume to up to **16 EC2 instances at once** (EBS Multi-Attach), mount it with a **cluster filesystem (GFS2)** so every instance sees the same files coherently, and let **one writer** update the data while **up to 15 read-only followers** serve reads from the very same files. An **Application Load Balancer** spreads read traffic across the fleet.

The result: read throughput scales almost linearly with instance count, while there is still exactly one copy of the data on disk — adding a replica adds **compute and cache, not storage**.

We demonstrate the pattern with [RocksDB](https://rocksdb.org/), an embedded key-value store whose read-only **secondary** mode (`OpenAsSecondary`) opens the same files without taking the writer lock and catches up every ~10 ms. **RocksDB is the example, not the point** — see [Generalizing beyond RocksDB](#generalizing-beyond-rocksdb).

---

## The problem it solves

A normal RocksDB deployment hits a wall when read traffic grows:

- Only one process can open the database, so you cannot just add more readers.
- The usual fixes — replicating the data to more machines, or sharding it — mean **copying terabytes around**, keeping copies in sync, and operating a much more complex system.

This project removes the copying entirely. New read replicas attach to the *existing* volume and start serving in minutes, because there is nothing to copy.

## The value

| Benefit | Detail |
|---|---|
| **Instant read replicas** | A new reader serves traffic ~5 min after you ask for it — no data copy, regardless of database size. |
| **One copy of data** | 1 TB of data costs 1 TB of storage, not 1 TB × number of replicas. |
| **Linear read scale-out** | Measured up to **~242,000 reads/sec** across 16 nodes (warm cache; see [Stress Testing](docs/10-stress-testing.md)). |
| **No write disruption** | The writer stays available while readers are added, removed, or replaced. |
| **Fast failover** | Any reader can be promoted to writer in ~1.5 minutes. |

> **Scope.** This design is purpose-built for **read-heavy workloads over a large, cacheable dataset**. It makes deliberate trade-offs to do that well — single Availability Zone, one shared volume (a single failure domain), and a single writer. See [When to use this](docs/01-overview.md#when-to-use-this-and-when-not-to) for where it fits and where it doesn't.

---

## Why one volume, many instances — the key strength

A fair question: *if all 16 instances read from the same EBS volume, what does adding instances actually buy you? Isn't the disk the bottleneck?*

The key insight is that **serving a read is mostly CPU, network, and RAM work — not disk work.** A served read accepts a connection, runs the HTTP server, looks up the key, and ships bytes over the NIC. The disk is only touched on a *cache miss*. So the thing that scales reads is **compute and cache**, and that is exactly what extra instances add — over a single shared copy of the data.

**1 instance vs 16 instances, same single volume:**

| Resource | 1 EC2 + 1 volume | 16 EC2 + same volume | Scales? |
|---|---|---|---|
| Request-serving CPU / NIC | one box (~15K reads/sec measured) | 16 boxes (~242K reads/sec measured) | ✅ ~16× |
| RAM page cache (hot data in memory) | ~32 GB | ~512 GB aggregate | ✅ ~16× |
| Disk IOPS | 256K (shared) | 256K (**still shared**) | ❌ fixed |
| Storage cost | 1× | 1× (one copy) | — |

So adding instances multiplies the two things that actually gate read throughput for most read-heavy workloads — **per-node CPU/NIC and cache**. The more of the working set that fits the fleet's combined RAM, the less the shared volume is touched: across the stress tests EBS stayed **well under** the 256K provisioned ceiling (≈35K IOPS cache-hot, ≈100–116K under the heaviest warm-cache load) while the fleet served **~90K–242K reads/sec** — i.e. the per-node service tier, not the volume, was the limit. A single instance simply cannot match 16 instances' aggregate CPU, network, and cache, no matter how fast the volume is.

**What it does *not* scale: disk IOPS.** All instances share the one volume's 256K-IOPS budget. For reads that genuinely miss cache — random reads over a dataset far larger than the fleet's combined RAM — the shared volume is a hard ceiling, and adding instances won't raise it. That regime is where a shared-nothing design (separate volumes, replication/sharding) wins instead — at the cost of N copies of the data and far higher storage spend (and note that 16 *separate* high-IOPS io2 volumes would be enormously expensive, so each would in practice get only a fraction of the IOPS this one volume provides).

**In one line:** this design scales **compute + cache over one copy of data**, which is the win for read-heavy workloads whose working set is cacheable; it does not scale disk IOPS, which is its boundary. See [Overview](docs/01-overview.md#when-to-use-this-and-when-not-to) for the full trade-off discussion.

---

## Generalizing beyond RocksDB

The reusable core of this solution has nothing to do with RocksDB:

- **One shared copy** — a single EBS Multi-Attach io2 volume, up to 16 instances, one physical dataset.
- **Coherent shared mount** — GFS2 + DLM so every node sees the same files in real time.
- **Safety** — Corosync/Pacemaker/fencing (STONITH) stop a misbehaving node from corrupting the shared disk.
- **Automation** — single-writer election, one-at-a-time join, fencing-aware scale-down, promote/failover, and a load balancer that only routes to ready nodes.

What's database-specific is just **how the engine reads the shared copy**. RocksDB is a clean fit because `OpenAsSecondary()` gives a lock-free, catch-up read follower. The pattern adapts to other stores to the extent they can do something similar:

| Workload | Fit | Why |
|---|---|---|
| Embedded/LSM stores with a follower/secondary read mode | **Strong** | Same as RocksDB — open the shared files read-only and catch up. |
| Immutable-segment search indexes (e.g. Lucene/OpenSearch segments) | **Good** | Segments are write-once; readers can open the same segment files. |
| File-based readers opened strictly read-only (e.g. SQLite read-only) | **Possible** | Works over a coherent shared FS; mind the engine's caching/locking semantics. |
| Engines that hold an exclusive lock on their files, or aren't safe for concurrent external readers | **Poor** | The shared-disk read-follower model doesn't apply directly. |

In short: the **storage + cluster + automation layers are a reusable blueprint**; porting to another database is mostly a matter of wiring up that engine's read-only/follower open path in place of RocksDB's secondary mode. The operational learnings here — cluster-filesystem safety, fencing-aware scaling, single-writer election, ready-gated load balancing — carry over regardless of engine.

---

## Read the docs in order

| # | Document | What you'll learn |
|---|----------|-------------------|
| 1 | [Overview](docs/01-overview.md) | The problem, the solution, the value, when (not) to use it, and a glossary |
| 2 | [Architecture](docs/02-architecture.md) | The components, how they fit together, and how data and requests flow |
| 3 | [Storage Layer: EBS Multi-Attach + GFS2](docs/03-storage-layer.md) | How one disk is shared across 16 machines, and why a special filesystem is needed |
| 4 | [Cluster Stack](docs/04-cluster-stack.md) | Corosync, Pacemaker, DLM, fencing — the machinery that keeps the shared disk safe |
| 5 | [RocksDB & the REST Service](docs/05-rocksdb-service.md) | Primary/secondary RocksDB, the catch-up mechanism, and the HTTP API |
| 6 | [Components & Code](docs/06-components.md) | A file-by-file tour of the codebase and the AMI build pipeline |
| 7 | [Operations](docs/07-operations.md) | Deploy, scale, promote, kill, read/write, recovery, and timings |
| 8 | [The TUI](docs/08-tui.md) | The terminal dashboard — what it shows and every command |
| 9 | [Testing](docs/09-testing.md) | How it's tested, what's covered, and the test harness |
| 10 | [Stress Testing](docs/10-stress-testing.md) | Performance results at full scale |
| 11 | [Troubleshooting](docs/11-troubleshooting.md) | Known failure modes and how they were fixed |
| 12 | [API Reference](docs/12-api-reference.md) | Every REST endpoint, SSM parameter, and file |
| 13 | [Security](docs/13-security.md) | Network/auth posture and the threat-model summary |

---

## Quick start

```bash
# 1. Build the machine image (one-time, ~16 min)
./scripts/build_ami.sh

# 2. Deploy the stack (~3 min) — creates VPC, ASG (1 node), ALB, the shared EBS volume
./deploy.sh

# 3. Wait ~2 min for the first node to set itself up as the writer, then open the dashboard
./tui.sh
```

In the TUI, try: `scale 3`, `write hello world`, `read 1 hello` (from node 1) or `read hello` (via the ALB), `scan 1`, then `scale 1`.

The dashboard and all operator tooling reach nodes through **AWS SSM** (Session Manager / Run Command) — there is no public SSH; port 22 is closed to the internet. See [Operations](docs/07-operations.md) and [The TUI](docs/08-tui.md) for the full guide.

---

## Key numbers

| Metric | Value |
|---|---|
| Max instances on one volume | 16 (1 writer + 15 readers) — an EBS Multi-Attach hard limit |
| Time to add a read replica | ~5 min, independent of data size |
| Scale up full fleet (1 → 16) | **~14 min end-to-end** (issue command → all 16 nodes serving; ~3 min ASG boot + ~40 s/node join) |
| Scale down full fleet (16 → 1) | **~3 min end-to-end** |
| Read staleness | ~10 ms (reader catch-up interval) |
| Promote a reader to writer | ~1.5 min |
| Peak read throughput (measured) | ~242,000 reads/sec across 16 nodes (warm cache) |
| Volume performance | io2 Block Express, 1,000 GiB, 256,000 provisioned IOPS |

## Project layout

```
/
├── app.py                  # CDK app entry point
├── rocksdb_stack.py        # CDK stack: VPC, ASG, ALB, EBS, IAM, instance boot script
├── tui.py                  # Terminal dashboard / cluster manager
├── deploy.sh / destroy.sh  # CDK deploy / destroy wrappers
├── scripts/                # AMI build, the RocksDB service, and cluster management
├── test/                   # Functional test harness (mirrors the TUI commands)
├── stress-test/            # Performance / load-test suite
└── docs/                   # This documentation
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
