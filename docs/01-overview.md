[Home](../README.md) · [Architecture →](02-architecture.md)

# 1. Overview

> **The solution in one sentence:** scale read replicas with *zero data copying* by putting one physical copy of your dataset on an **EBS Multi-Attach** volume, mounting it coherently on up to 16 EC2 instances with a **cluster filesystem**, and fanning reads across the fleet behind a load balancer. **RocksDB is the worked example** in these docs, but the storage + cluster + automation blueprint generalizes to other read-heavy stores — see [Generalizing beyond RocksDB](../README.md#generalizing-beyond-rocksdb).
>
> **Status:** this is a **proof of concept** — fully working and measured on AWS, but **not production-hardened** (single AZ, single shared volume, single writer, unauthenticated plaintext data plane, no backups). See [When to use this](#when-to-use-this-and-when-not-to) and [Security](13-security.md).

## Why scaling reads is hard (illustrated with RocksDB)

[RocksDB](https://rocksdb.org/) is an embedded key-value store: a high-performance database that runs as a *library inside your application process*, storing data in local files. It powers the storage engine behind many well-known systems (databases, streaming platforms, ledgers). We use it as the concrete example throughout — its constraints make the read-scaling problem vivid, and its read-only *secondary* mode makes the shared-disk solution clean.

Because it is embedded, it has two properties that make horizontal read scaling difficult:

1. **Single process.** RocksDB is opened by one process on one machine. There is no built-in network server and no built-in way for other machines to read the data.
2. **Single writer lock.** RocksDB takes an exclusive OS lock (`LOCK` file) on the database directory when opened read-write. Only one process, anywhere, can hold it.

So if your read traffic outgrows one machine, your usual options are:

| Option | Cost |
|---|---|
| **Replicate** the data to more machines | Copy the entire dataset to each replica; keep all copies in sync forever |
| **Shard** the data across machines | Split data by key range; add a routing layer; rebalance when nodes change |
| **Bigger machine** | Eventually you run out of "bigger" |

All of these involve moving data around and operating a more complex system.

## The idea behind this project

What if every machine could read **the exact same files**, instead of its own copy?

That is what this system does. It combines three AWS / Linux capabilities so that one physical copy of the database is visible to many machines at once:

1. **EBS Multi-Attach** — AWS lets a single io2 EBS volume attach to up to 16 EC2 instances at the same time. Every instance sees the same block device.
2. **GFS2, a cluster filesystem** — a normal filesystem (ext4, XFS) corrupts instantly if two machines mount it at once. GFS2 is built for exactly this: many machines mounting one disk with full, coherent, real-time file visibility.
3. **RocksDB Secondary Instances** — RocksDB can open a database directory in a special read-only "secondary" mode (`OpenAsSecondary`) without taking the writer lock. A secondary periodically calls `TryCatchUpWithPrimary()` to pick up the writer's new files.

Put together:

- One instance is the **writer** — it opens RocksDB read-write and is the only one that can change data.
- Up to fifteen instances are **readers** — each opens the *same files* as a secondary and refreshes every ~10 ms.
- A load balancer fans read traffic across all of them.

There is still only **one copy of the data on disk**. Adding a reader adds compute and cache, not storage.

## How it compares

```
Traditional replication                This project
───────────────────────                ────────────
 Writer        Replica A                 Writer    Reader    Reader
   │              │                          \        |        /
 [disk 1]      [disk 2]  ← full copy          \       |       /
   │              │                          ┌──────────────────┐
 (replication stream keeps                   │  ONE shared disk │
  disk 2 in sync with disk 1)                └──────────────────┘
                                          (everyone reads the same blocks)
 N replicas = N copies of the data       N readers = 1 copy of the data
 New replica = copy whole dataset        New reader = attach + mount (~5 min)
```

## The value and impact

| Benefit | Why it matters |
|---|---|
| **No data copying to scale reads** | A new reader is serving traffic in ~5 minutes whether the database is 1 GB or 1 TB. Replication time normally grows with data size; here it is constant. |
| **Storage cost is flat** | You pay for one volume, not one-per-replica. A 1 TB dataset across 16 readers is still 1 TB of storage. |
| **Linear read scale-out** | Each reader adds its own CPU and OS page cache. Measured up to **~242,000 reads/sec** across 16 nodes (warm cache), with zero errors (see [Stress Testing](10-stress-testing.md)). |
| **Reads stay fresh** | Readers catch up to the writer within ~10 ms. |
| **Elastic** | Scale up or down quickly. **Measured end-to-end** — from issuing the command to every node serving traffic: a full **1→16 takes ~14 min** (≈3 min for the ASG to launch+boot the 15 instances, then the writer joins them ~40 s each), and a **16→1 takes ~3 min**. The writer and existing readers stay available the whole time. |
| **Fast failover** | Promote any reader to writer in ~1.5 minutes — it already has the data mounted. |

## When to use this (and when not to)

**A good fit when:**
- Reads vastly outnumber writes and you need to scale reads quickly.
- The dataset is large enough that copying it to each replica is painful.
- A short, controlled failover window for the single writer is acceptable.

**Not a good fit when (the trade-offs):**

| Limitation | Consequence |
|---|---|
| **Single Availability Zone** | EBS Multi-Attach requires all instances in the same AZ as the volume. No multi-AZ resilience. |
| **Single volume = single failure domain** | If the one EBS volume fails, the whole cluster is affected. |
| **Single writer** | Only one node can write at a time. Write throughput does not scale; the writer is a failover point. |
| **16-instance ceiling** | A hard EBS Multi-Attach limit. |
| **Shared IOPS** | All instances share the volume's provisioned IOPS budget. |
| **Operational complexity** | A full cluster stack (Pacemaker/Corosync/DLM/fencing) must stay healthy for the shared filesystem to work. |
| **Security posture** | In-VPC HTTP only (no TLS), a single shared admin token on `/admin/*`, and an unauthenticated data plane — acceptable for the locked-down network it runs in, but review it for your environment. See [Security](13-security.md). |

This is **purpose-built for one job** — fanning out reads over a large, cacheable dataset — and makes the deliberate trade-offs below to do it well. Weigh those trade-offs against your workload before production use.

## Glossary

| Term | Meaning |
|---|---|
| **Writer** | The single instance that opened RocksDB read-write. Tagged `rocksdb-role=writer`. |
| **Reader** | An instance that opened the same DB as a read-only RocksDB *secondary*. Tagged `rocksdb-role=reader`. |
| **EBS Multi-Attach** | AWS feature: one io2 volume attached to up to 16 instances at once. |
| **GFS2** | Global File System 2 — a cluster filesystem that lets many machines mount one disk coherently. |
| **Cluster stack** | Corosync + Pacemaker + DLM + fencing — the software that makes GFS2 safe across nodes. |
| **DLM** | Distributed Lock Manager — coordinates file/metadata locks across nodes for GFS2. |
| **Fencing (STONITH)** | "Shoot The Other Node In The Head" — forcibly killing a misbehaving node so it can't corrupt shared data. |
| **Secondary instance** | RocksDB read-only mode that follows a primary's files without holding the write lock. |
| **Catch-up** | A reader calling `TryCatchUpWithPrimary()` to pick up the writer's latest data (every ~10 ms). |
| **Cluster watcher** | A daemon on the writer that adds/removes nodes from the cluster as the fleet scales. |
| **ASG** | AWS Auto Scaling Group — manages the 1–16 EC2 instances. |
| **TUI** | The terminal dashboard (`tui.py`) used to operate the cluster. |

---
Next: [Architecture →](02-architecture.md)
