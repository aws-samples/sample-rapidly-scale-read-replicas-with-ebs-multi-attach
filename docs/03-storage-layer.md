[← Architecture](02-architecture.md) · [Home](../README.md) · [Cluster Stack →](04-cluster-stack.md)

# 3. Storage Layer — EBS Multi-Attach + GFS2

This is the foundation everything else stands on: **one disk that 16 machines can read and write at the same time, safely.** It takes two technologies working together.

- **EBS Multi-Attach** makes one disk *physically reachable* from many instances.
- **GFS2** makes that disk *safe to actually use* from many instances at once.

You need both. Multi-Attach alone gives you a shared block device that a normal filesystem will corrupt instantly.

---

## Part 1 — EBS Multi-Attach

### What it is

Normally an EBS volume attaches to exactly one EC2 instance. **Multi-Attach** is an AWS feature for `io1`/`io2` volumes that lets a single volume attach to **up to 16 instances in the same Availability Zone simultaneously**. Every attached instance sees the same block device and can issue reads and writes to the same blocks.

In this project the volume is created in `rocksdb_stack.py`:

```python
data_volume = ec2.CfnVolume(self, "RocksDbDataVolume",
    availability_zone=az,
    volume_type="io2",
    size=1000,            # GiB — Block Express unlocks max IOPS at >= 1000 GiB
    iops=256000,          # provisioned IOPS (max for io2 Block Express)
    multi_attach_enabled=True,
)
```

### How instances attach to it

The volume isn't attached by CloudFormation. Each instance attaches *itself* on boot (in the userdata script), so the same launch template works for 1 or 16 nodes:

1. The volume ID is published to SSM Parameter Store at deploy time (`/rocksdb-cluster/volume-id`).
2. On boot, each instance reads that parameter and calls `aws ec2 attach-volume` for its own instance ID.
3. Because up to 16 instances do this near-simultaneously, the script adds a random 0–30 s jitter and retries up to 30 times (attach calls can briefly conflict).

### Finding the device reliably

The instance type is `m5d.2xlarge`, which also has a *local* NVMe SSD. That means the shared EBS volume shows up under an unpredictable kernel name (`nvme1n1`, `nvme2n1`, …) that differs per instance. To get a stable path, the code uses the volume's serial number under `/dev/disk/by-id/`:

```
/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id-without-dashes>
```

This path is identical on every instance and survives reboots.

### What Multi-Attach gives you and what it does NOT

Multi-Attach provides **shared block access** — nothing more. It does **not** coordinate writes. If two instances write overlapping blocks, or if a normal filesystem on top assumes it's the only mounter, you get corruption. AWS is explicit that Multi-Attach requires a *cluster-aware filesystem* on top. That's what GFS2 is for (Part 2).

### Limitations (important)

| Limitation | Detail |
|---|---|
| **16 attachments max** | Hard limit → the cluster's 16-node ceiling. |
| **Same AZ only** | All instances must be in the volume's Availability Zone. No multi-AZ. |
| **io1 / io2 only** | gp2, gp3, st1, sc1 do **not** support Multi-Attach. |
| **No I/O fencing built in** | Multi-Attach does not stop a rogue node from writing. You must add fencing yourself (see [Cluster Stack](04-cluster-stack.md)). |
| **Standard filesystems forbidden** | ext4/XFS will corrupt. A cluster filesystem is mandatory. |
| **Shared performance budget** | The 256K IOPS are shared across all attached instances, not per-instance. |
| **Single failure domain** | It is still one volume. Its failure affects every node. |

### Why io2 Block Express specifically

- **Multi-Attach support** (gp3 cannot do this).
- **256,000 IOPS and sub-millisecond latency**, which a 16-node read fleet can actually consume.
- **Block Express** (the io2 architecture that unlocks the highest performance) requires the volume to be ≥ 1,000 GiB, which is why the volume is sized at 1,000 GiB.

---

## Part 2 — GFS2, the cluster filesystem

### The problem GFS2 solves

A filesystem is mostly bookkeeping: which blocks belong to which file, directory contents, inode metadata, free-space maps. A normal filesystem keeps much of that bookkeeping **cached in the kernel of the one machine that mounted it**, and assumes nobody else touches the disk.

Put two normal-filesystem mounters on one Multi-Attach volume and they immediately disagree about that bookkeeping — each caches stale metadata, both allocate the same "free" blocks, and the filesystem is destroyed in seconds.

**GFS2 (Global File System 2)** is a *cluster* filesystem built for shared-disk setups. Every node mounts the same volume, and GFS2 keeps their views coherent so that a file the writer creates is immediately and correctly visible to all readers.

### How GFS2 stays coherent: the DLM

GFS2's coherence comes from the **Distributed Lock Manager (DLM)**. Before any node touches a piece of filesystem metadata (open a file, read a directory, update an inode), it must acquire the corresponding lock through the DLM, which coordinates across all nodes.

```
Writer creates new SST file:
   1. acquires DLM lock on the directory inode
   2. writes the file + updates metadata on the shared volume
   3. releases the lock
Reader lists the directory:
   1. acquires DLM lock (sees the writer's update is committed)
   2. reads the now-current directory → sees the new SST file
```

This is what makes "the writer flushes a file and ~10 ms later every reader sees it" actually work. DLM is covered in detail in [Cluster Stack](04-cluster-stack.md).

### Journals — one per node

GFS2 uses a **per-node journal** for crash consistency. Each mounting node writes metadata-change intentions to its own journal first; if a node dies, surviving nodes **replay its journal** to bring the filesystem back to a consistent state.

This system pre-creates **16 journals** when the volume is first formatted (`mkfs.gfs2 -j16`), one for every possible node. Pre-creating them means a new reader can mount **immediately** without reformatting or growing journals on the fly.

```
mkfs.gfs2 -j16 -p lock_dlm -t rocksdb-cluster:rocksdb -O <device>
            │        │          │
            │        │          └ lock table name: <cluster>:<fsname>
            │        └ use DLM for locking (cluster mode)
            └ 16 journals
```

### How it's mounted

GFS2 is **not** mounted via `/etc/fstab`. It's managed by Pacemaker as a *cloned resource* — meaning Pacemaker mounts it on every node and keeps it mounted, in the right order (only after DLM is up). It mounts at `/data/rocksdb` with the `noatime` option (don't write access-time metadata on every read — a meaningful saving for a read-heavy workload).

The RocksDB database lives at `/data/rocksdb/db`.

### Why GFS2 and not something else

Several shared-disk approaches were tried; only GFS2 worked end-to-end on this stack:

| Approach | Result |
|---|---|
| **ext4** on Multi-Attach | `EIO` errors and corruption — journal conflicts between mounters. |
| **XFS** mounted `ro,norecovery` | Read-only snapshot only — readers never see the writer's *new* files. |
| **OCFS2** on Ubuntu 24.04 | Its O2CB cluster stack doesn't come up cleanly on AWS. |
| **GFS2** on Ubuntu 24.04 | **Works** — full, coherent, real-time cross-node visibility via DLM. |

GFS2's dependency on a full cluster stack (Corosync/Pacemaker/DLM/fencing) is the price of that coherence — and the subject of the next chapter.

### GFS2 facts at a glance

| Property | Value |
|---|---|
| Mount point | `/data/rocksdb` |
| Mount option | `noatime` |
| Journals | 16 (one per possible node) |
| Lock protocol | `lock_dlm` (cluster mode via DLM) |
| Managed by | Pacemaker cloned resource `gfs2fs` |
| Start dependency | DLM clone must be running first |
| Resource timeouts | 300 s (allows recovering up to 15 journals at once after a mass termination) |

---
Next: [Cluster Stack →](04-cluster-stack.md)
