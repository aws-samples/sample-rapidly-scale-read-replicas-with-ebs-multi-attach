[← Overview](01-overview.md) · [Home](../README.md) · [Storage Layer →](03-storage-layer.md)

# 2. Architecture

This page shows how the pieces fit together and how data and requests move through the system. The next four chapters deep-dive each layer.

## The big picture

```
                          Internet (read clients)
                                   │
                                   ▼
                ┌───────────────────────────────────────┐
                │   Application Load Balancer (ALB)       │
                │   port 80  →  :8080 on every node       │
                │   reads only: /get · /scan (writes 403)  │
                │   health check: GET /health            │
                └───────────────────┬─────────────────────┘
            ┌──────────────┬────────┴───────┬──────────────┐
            ▼              ▼                ▼              ▼
     ┌────────────┐ ┌────────────┐  ┌────────────┐ ┌────────────┐
     │  WRITER     │ │  READER 1   │  │  READER 2  │ │  READER N  │   (1 + up to 15)
     │  :8080 REST │ │  :8080 REST │  │ :8080 REST │ │ :8080 REST │
     │  RocksDB    │ │  RocksDB    │  │  RocksDB   │ │  RocksDB   │
     │  read/write │ │  secondary  │  │  secondary │ │  secondary │
     │  + watcher  │ │  (catch-up) │  │ (catch-up) │ │ (catch-up) │
     └─────┬──────┘ └─────┬───────┘  └─────┬──────┘ └─────┬──────┘
           │              │                │              │
           │   GFS2 mounted at /data/rocksdb on every node simultaneously
           └──────────────┴───────┬────────┴──────────────┘
                                   ▼
                  ┌────────────────────────────────────┐
                  │  io2 Block Express EBS volume        │
                  │  Multi-Attach, 1000 GiB, 256K IOPS   │
                  │  ONE physical copy of the data       │
                  └────────────────────────────────────┘

  Coordination plane (not in the data path):
    Corosync (membership) → Pacemaker (resources) → DLM (locks) → GFS2 (mount)
    fence_aws (STONITH via EC2 API)   ·   SSM Parameter Store (keys, volume id, writer id, admin token)
```

Everything lives in a **dedicated VPC**, in a **single Availability Zone** (an EBS Multi-Attach requirement). The ALB spans two AZs because an ALB requires two, but all EC2 and EBS resources sit in one AZ.

## The four layers

The system is best understood as four stacked layers. Each chapter below covers one.

| Layer | What it does | Built from | Chapter |
|---|---|---|---|
| **1. Shared block storage** | One disk visible to 16 machines | EBS io2 Multi-Attach | [3](03-storage-layer.md) |
| **2. Cluster filesystem** | One disk *safely mountable* by 16 machines, with coherent real-time file visibility | GFS2 + DLM | [3](03-storage-layer.md) |
| **3. Cluster coordination** | Keeping membership, locks, and fencing correct as nodes come and go | Corosync, Pacemaker, fence_aws | [4](04-cluster-stack.md) |
| **4. Database + API** | One writer, many read-only followers, exposed over HTTP | RocksDB primary/secondary + C++ REST service | [5](05-rocksdb-service.md) |

Each layer depends on the one below it. The boot order reflects this: Corosync → Pacemaker → DLM → GFS2 mount → RocksDB service.

## The components

### AWS infrastructure (defined in `rocksdb_stack.py`)

| Component | Role |
|---|---|
| **VPC** (single AZ for compute) | Network isolation. Public subnets; no NAT. |
| **Auto Scaling Group (ASG)** | Manages 1–16 EC2 instances (`m5d.2xlarge`). Desired capacity = cluster size. |
| **Launch Template** | Defines the instance: the custom AMI + the boot script (userdata) that makes a node a writer or reader. Enforces **IMDSv2** with a metadata hop limit of 1 (mitigates SSRF credential theft). |
| **io2 Multi-Attach EBS volume** | The single shared data disk. 1,000 GiB, 256,000 IOPS, encrypted at rest (KMS). |
| **Application Load Balancer** | Fans read traffic across all healthy nodes on port 80 → 8080. It's a **read-only data plane**: listener rules return **HTTP 403 for any `/admin/*` path and for the writer-only endpoints** (`/put`, `/batch-put`, `/delete`, `/flush`), so neither admin actions nor writes are served through the public load balancer — only `/get`, `/scan`, and `/health`. Access logs are written to S3. |
| **Security group** | Port 8080 is reachable **only from the ALB security group**; SSH (22) is **closed to the internet** (operators use SSM Session Manager; optional break-glass via the `admin_ssh_cidr` CDK context). Cluster/Corosync traffic is restricted to fellow cluster members via a self-referencing rule (not the whole VPC CIDR). |
| **IAM role** | Lets instances self-attach the volume, tag themselves, call the EC2 API for fencing, and read/write SSM. Scoped to least privilege (SSM `/rocksdb-cluster/*`, KMS via-ssm, EC2 `instance/*`+`volume/*`; only `autoscaling:*` stays `*`). Includes the **`AmazonSSMManagedInstanceCore`** managed policy so the SSM agent registers and operators can use Session Manager / Run Command instead of SSH. |
| **SSM Parameter Store** | Shared state: volume ID, cluster auth keys, current writer instance ID, and the **admin bearer token** (SecureString) that gates all `/admin/*` and `/cluster/*` endpoints. |

### On-instance software (baked into the AMI)

| Component | Role |
|---|---|
| **`rocksdb_service`** | C++ HTTP server wrapping RocksDB. Runs on every node in `readwrite` or `readonly` mode. |
| **Cluster stack** | Corosync, Pacemaker, DLM, GFS2 utilities, fence agents. |
| **`cluster_watcher.sh`** | Daemon on the writer that adds/removes nodes from the cluster as the ASG scales. |
| **`fence_aws` (wrapped)** | STONITH agent that fences nodes via the EC2 API. |
| **systemd units** | `rocksdb.service`, `cluster-watcher.service`, `cluster-self-remove.service` (shutdown hook), `cluster-key-sync.timer`. |

### Operator tooling

| Component | Role |
|---|---|
| **`tui.py`** | Terminal dashboard to view and drive the cluster, via SSM Run Command — see [The TUI](08-tui.md). |
| **`test/`** | Functional test harness mirroring the TUI commands, driven over SSM — see [Testing](09-testing.md). |
| **`stress-test/`** | Load-test suite — see [Stress Testing](10-stress-testing.md). |

## How a write reaches the readers (data flow)

```
Client → POST /put {"key":"user:1","value":"Alice"}  → WRITER
   │
   1. RocksDB writes the change to its WAL on GFS2        (durable immediately)
   2. RocksDB updates its in-memory memtable
   3. The service triggers an async flush → a new SST file lands on GFS2
   │
   │   Meanwhile, every READER runs TryCatchUpWithPrimary() every ~10 ms:
   4.   - re-reads the MANIFEST → discovers the new SST file
   5.   - replays new WAL entries → sees writes not yet flushed
   │
   ▼
Within ~10 ms, every reader returns "user:1" = "Alice"
```

Because all nodes share the same GFS2 filesystem, the writer's new files are *physically the same files* the readers see — there is no network replication of data, just RocksDB re-reading the shared directory.

## How a read is served (request flow)

```
Client → GET / (read) → ALB → any healthy node (writer or reader)
                                      │
                                      ▼
                         rocksdb_service GET /get or /scan
                                      │
                                      ▼
                         RocksDB reads from GFS2 / page cache
                                      │
                                      ▼
                                  JSON response
```

The ALB only routes to nodes whose `GET /health` returns `200`. A node returns `503` until its RocksDB is open and (for readers) GFS2 is mounted — so traffic is never sent to a node that isn't ready.

## How the fleet changes size (process flows, high level)

These are summarized here and detailed in [Operations](07-operations.md) and [Cluster Stack](04-cluster-stack.md).

**Scale up (add readers).** You raise the ASG desired capacity → new instances boot from the AMI → each runs the boot script, sees a cluster already exists, attaches the volume, tags itself `rocksdb-join` → the writer's `cluster_watcher.sh` detects the tag and joins it to the Corosync/Pacemaker cluster → GFS2 mounts → the reader starts serving. Roughly **~40 s/node** once the ASG has booted the new instances; **~14 min end-to-end for a full 1→16** (measured, command → all 16 serving, including the ~3 min ASG boot).

**Scale down (remove readers).** You lower desired capacity → the ASG terminates instances → each runs a shutdown hook (`cluster-self-remove`) that leaves the cluster cleanly → the watcher purges the departed node from config → GFS2 recovers the node's journal. A full 16→1 takes ~3 min end-to-end (measured ~173 s).

**Promote (failover).** You promote a reader → the current writer is demoted to read-only in place → the target reader removes the RocksDB `LOCK`, reopens read-write, and starts the watcher → SSM/tags updated. ~1.5 min.

**Kill / recover.** An instance is terminated (planned or not) → Corosync detects it gone → Pacemaker fences it via the EC2 API → GFS2 recovers its journal → the ASG launches a replacement that re-joins. ~5–7 min (measured 7m20s) — dominated by the replacement's EC2 boot + rejoin.

## Where state lives

| State | Where | Why there |
|---|---|---|
| The data | The single GFS2/EBS volume | One shared copy |
| Who is the writer | EC2 tag `rocksdb-role=writer` + SSM `writer-instance-id` | New nodes check this on boot to decide writer vs reader |
| Cluster membership | `/etc/corosync/corosync.conf` (on every node) | Corosync's node list |
| Cluster auth keys | SSM (SecureString) | New readers fetch them to join |
| Admin bearer token | SSM `admin-token` (SecureString) → `/etc/rocksdb/service.env` as `ADMIN_TOKEN` | Gates all `/admin/*` endpoints; read on-box only, never leaves the instance |
| Next node ID | `/data/rocksdb/.next_nodeid` on GFS2 | Monotonic IDs, shared across the fleet (see [Cluster Stack](04-cluster-stack.md#node-ids-why-they-never-repeat)) |
| Join-watchdog timers | `/data/rocksdb/.join_watch/<ip>` on GFS2 | How long each joining node has been pending; a node stuck > 6 min is recycled (see [Cluster Stack](04-cluster-stack.md#join-watchdog-reap_stuck_join_nodes)) |

---
Next: [Storage Layer: EBS Multi-Attach + GFS2 →](03-storage-layer.md)
