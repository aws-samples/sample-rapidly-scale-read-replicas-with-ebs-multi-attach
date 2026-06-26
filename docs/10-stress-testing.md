[← Testing](09-testing.md) · [Home](../README.md) · [Troubleshooting →](11-troubleshooting.md)

# 10. Stress Testing

Where [functional testing](09-testing.md) asks *"is it correct?"*, stress testing asks *"how fast and how stable is it at full scale?"* — 1 writer + 15 readers under sustained high read load.

## How it's run

Via the TUI:

```
stress-test <size> <loaders> <mins>
```

- `<size>` — dataset to preload: `1gb`, `10gb`, `100gb`, `1tb`, or `2tb` (sets the number of keys). Must fit the volume — the TUI refuses a size that would exceed ~90% of the EBS volume (see the sizing note under [Dataset sizes](#dataset-sizes-incompressible)).
- `<loaders>` — number of `c5.4xlarge` load-generator instances to launch. Each is 16 vCPU, so the TUI checks `loaders × 16` against your EC2 On-Demand vCPU quota and refuses if it would exceed it (e.g. 100 loaders = 1600 vCPUs).
- `<mins>` — how long to drive load.

Example: `stress-test 1gb 20 10` preloads ~1M keys, launches 20 loaders, runs 10 minutes.

The preload runs detached on the writer and the TUI **streams live progress** (keys/sec) rather than blocking silently, with a wall-clock cap so a stalled run can't hang the TUI.

> The preload and monitoring drive the writer over **SSM Run Command** (no SSH) — `01_preload_data.sh` compiles and runs `sst_generator.cc` on the writer via SSM, and `02_scale_to_max.sh` / `04_run_stress.sh` operate over SSM and the AWS APIs. On the token=30000 fleet, scaling to 16 (`02_scale_to_max.sh`) completes in **~14 min end-to-end**.

Or via the shell scripts in `stress-test/`, which the TUI runs for you:

| Step | Script | Purpose |
|---|---|---|
| 1 | `01_preload_data.sh` | Compile and run `sst_generator.cc` on the writer to bulk-load data. **Refuses a dataset > 90% of the volume** (same guard as the TUI); default ~100 GB. |
| 2 | `02_scale_to_max.sh` | Scale the ASG to 16 and wait for all nodes to join (InService + ALB-healthy + cluster Online). |
| 3 | `03_launch_loaders.sh` | Launch `c5.4xlarge` loaders running `wrk` against the ALB (random key reads). **Refuses if `count × 16` exceeds the On-Demand vCPU quota** (same guard as the TUI); default 20 loaders. |
| 4 | `04_run_stress.sh` | Sample CloudWatch metrics every 30 s (RPS, p99, 5xx, EBS IOPS/throughput, node count) and write a CSV to `results/`. |
| 5 | `05_teardown.sh` | Terminate all loaders (by ID and `Name=rocksdb-loader` tag), scale the cluster back to 1, and delete the loader security group. |

These shell scripts and the TUI's built-in `stress-test` command perform the same flow with the same safety guards; the TUI runs the steps for you, while the scripts let you run each phase manually.

## The preloader (`sst_generator.cc`)

Loading billions of keys over HTTP would be far too slow. `sst_generator.cc` writes RocksDB data **directly** on the writer, bypassing the HTTP API. It creates keys like `stress:0000000000000001` with 1 KB values.

> **The current generator writes incompressible (random) values** — every value is unique random bytes, so RocksDB compression has no effect and on-disk size ≈ logical size. (Earlier results below labelled "compressed" were produced by an older generator that wrote repeated-byte values; they're kept as historical data points.)

Preload throughput with incompressible values: **~232K keys/sec**.

### Dataset sizes (incompressible)

| Flag | Keys | On-disk size | Fits 1000 GiB volume? |
|---|---|---|---|
| `1gb` | 1,000,000 | ~1 GB | ✅ |
| `10gb` | 10,000,000 | ~10 GB | ✅ |
| `100gb` | 100,000,000 | ~98 GB | ✅ |
| `1tb` | 1,000,000,000 | ~984 GB | ⚠️ ~98% full — fits only by nearly filling the disk; the guard refuses it |
| `2tb` | 2,000,000,000 | ~1.9 TB | ❌ no |

> **Sizing constraint.** Because values are incompressible, on-disk size ≈ `keys × (1 KB + key + overhead)`. The shared volume is **1000 GiB**, so `1tb` (~984 GiB) only fits by running the volume to **~98% full** — leaving no headroom for GFS2 metadata, the WAL, or compaction — and `2tb` can't fit at all. [Test 3](#test-3--1-tb-incompressible-drives-real-ebs-load) below *did* run a near-1 TB dataset this way, **before this guard existed**. The TUI (and `01_preload_data.sh`) now **refuse a dataset that would exceed ~90% of the volume**, because filling the disk leaves the writer's DB destroyed and `rocksdb.service` stopped — the failure behind the apparent hang on `stress-test 1tb …`. To run `1tb`+ safely, grow the EBS volume first.

**Why incompressible matters:** it forces real EBS reads once the dataset exceeds the fleet's combined RAM (~512 GB across 16 nodes), which is the only way to actually exercise the volume's IOPS. A compressible dataset would just sit in page cache and never touch disk.

## Results

> **Measured 2026-06-17** on a freshly built AMI (`ami-04fe5971a3cab4500`), **16× `m5d.2xlarge`**
> (1 writer + 15 readers), io2 Multi-Attach volume (1000 GiB, 256K provisioned IOPS), us-east-1.
> Loaders are `c5.4xlarge` running `wrk -t16 -c1000`. Values are **incompressible** (random bytes),
> so on-disk size ≈ logical size and reads genuinely hit EBS once the working set exceeds RAM.
> Preload is SST-ingestion at **~224–240K keys/sec**.
>
> *Reading the RPS:* `04_run_stress.sh` samples the most recent CloudWatch 1-minute bucket, which
> alternates complete/partial — so the per-row RPS oscillates. The **sustained** figure below is the
> complete-bucket (higher) value; the dips are sampling artifacts, not real drops.

### Run A — cache-hot (100M keys / ~98 GB, 10 loaders)

| Metric | Value |
|---|---|
| Dataset | 100M × 1 KB ≈ 98 GB |
| Preload | 100M keys in **7.4 min** (~224K keys/sec) |
| Loaders | 10 × c5.4xlarge |
| ALB RPS (sustained) | **~90,000** (peak 91,647) |
| ALB p99 | **~80 ms** |
| EBS IOPS | ~35,000 |
| EBS throughput | ~260–298 MB/s |
| 5xx errors | **0** |
| Cluster | 16/16 Online throughout |

Working set (~98 GB) is smaller than the fleet's combined RAM (~512 GB across 16 nodes), so most
reads are served warm. EBS sits at ~35K IOPS — **well under** the 256K provisioned ceiling — so the
limit is reader CPU / block cache, not the volume.

### Run B — disk-bound (800M keys / ~781 GB, 16 loaders)

| Metric | Value |
|---|---|
| Dataset | 800M × 1 KB ≈ 781 GB (incompressible) |
| Preload | 800M keys in **55.5 min** (~240K keys/sec) |
| Loaders | 16 × c5.4xlarge |
| ALB RPS (sustained) | **~110,000** (complete-bucket peaks ~115K) |
| ALB p99 | **~375–600 ms** |
| EBS IOPS | **~40,000–65,000** |
| EBS throughput | ~300–400 MB/s |
| 5xx errors | **0** |
| Cluster | 16/16 Online throughout |

The 781 GB working set far exceeds the fleet's ~512 GB RAM, so reads fall through to EBS — IOPS rise
to ~40–65K and p99 climbs to the hundreds of ms. More loaders (16 vs Run A's 10) push higher RPS at
the cost of latency. Even here EBS used only **~25% of the 256K provisioned IOPS** — the shared
volume was not the bottleneck. Zero errors throughout.

### Run C — disk-bound, lighter load (same 781 GB, 8 loaders)

| Metric | Value |
|---|---|
| Dataset | same 781 GB as Run B (reused, no re-preload) |
| Loaders | 8 × c5.4xlarge |
| ALB RPS (sustained) | **~242,000** (complete-bucket peaks ~244K) |
| ALB p99 | **~21–45 ms** |
| EBS IOPS | **~100,000–116,000** |
| EBS throughput | ~790–900 MB/s |
| 5xx errors | **0** |
| Cluster | 16/16 Online throughout |

Run C ran on the **same cluster right after Run B**, so the readers' block caches were **warm** for
the 781 GB working set. Even with only 8 loaders, throughput jumped to **~242K RPS at p99 ~30 ms** —
~2× Run B's cold-cache result with half the loaders. EBS climbed to ~116K IOPS (~45% of the 256K
provisioned). This is the clearest illustration that **a warm fleet cache is the dominant factor**:
the same data, fewer load generators, but caches primed by the prior run → far higher throughput and
an order-of-magnitude lower latency than the cold-cache Run B.

### Summary

| Run | Dataset | Loaders | Cache state | RPS (sustained) | p99 | EBS IOPS |
|---|---|---|---|---|---|---|
| A — cache-hot | 98 GB | 10 | warm (fits RAM) | ~90K | ~80 ms | ~35K |
| B — disk-bound | 781 GB | 16 | cold (just scaled) | ~110K | ~375–600 ms | ~40–65K |
| C — disk-bound | 781 GB | 8 | warm (after B) | ~242K | ~21–45 ms | ~100–116K |

## What the numbers tell you

- **Read throughput scales with node count** — each reader adds CPU + cache; the fleet sustained
  **up to ~242K reads/sec** across 16 nodes (warm cache, Run C) with zero errors.
- **A warm fleet cache is the dominant factor** — Run C hit ~242K RPS @ ~30 ms with *8* loaders on
  warm caches, vs Run B's ~110K @ ~500 ms with *16* loaders on cold caches (same data). When the
  working set fits the fleet's combined RAM (Run A), EBS load is light (~35K IOPS).
- **Storage was never the limit** — even the busiest run used only ~45% of the provisioned 256K IOPS;
  the read ceiling is per-node service/CPU, not the shared volume.
- **Latency degrades gracefully** — warm ~30–80 ms p99 → cold disk-bound ~400–600 ms p99, with
  **0 5xx** across every run; 16/16 nodes stayed Online throughout.

## Cleanup note

Both the TUI and `05_teardown.sh` terminate loaders by instance ID and by tag. If `destroy.sh` later fails to delete the VPC, look for a leftover `rocksdb-loader-sg` security group and delete it.

---
Next: [Troubleshooting →](11-troubleshooting.md)
