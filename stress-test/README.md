# RocksDB Stress Test Suite

Tests the system at maximum scale: 1 writer + 15 readers on io2 Block Express (256,000 IOPS),
with a fleet of load generators bombarding the ALB with random-key reads.

## Prerequisites

- Stack deployed with writer only: `./deploy.sh`
- 16-node cluster running: `./stress-test/02_scale_to_max.sh` (or skip if already scaled)

## Test Sequence

```bash
# From /

# 1. Preload data (writer only, ASG=1 — stops rocksdb.service temporarily)
./stress-test/01_preload_data.sh [--keys 2000000000] [--value-size 1024]
# Default: 2B keys × 1KB = ~2TB. Takes ~32 min at ~1.06M keys/sec via SST ingestion.
# 2TB exceeds the 16-node fleet page cache (~512GB), forcing real EBS reads.

# 2. Scale to 16 nodes (1 writer + 15 readers)
./stress-test/02_scale_to_max.sh
# Takes ~3.5 min. All readers immediately see the full dataset.

# 3. Launch load generators (random-key wrk load test)
./stress-test/03_launch_loaders.sh [--count 60] [--duration 1200] [--concurrency 1000]
# Default: 60 × c5.4xlarge spot, 1000 concurrency each, 20 min duration.
# Uses wrk + Lua script for random key per request across full keyspace.

# 4. Monitor metrics in real time (results auto-saved to stress-test/results/<timestamp>.csv)
./stress-test/04_run_stress.sh [--duration 1200] [--interval 30]
# Shows every 30s: cluster nodes, ALB RPS, ALB p99 latency, EBS IOPS, EBS MB/s
# CSV saved to stress-test/results/YYYYMMDD_HHMMSS.csv

# 5. Teardown loaders (keep cluster running for more tests)
./stress-test/05_teardown.sh --keep-cluster

# 6. Full cleanup when done
./destroy.sh
```

## Why preload before scaling

`01_preload_data.sh` stops `rocksdb.service` on the writer to get exclusive DB access for
SST file ingestion — the fastest possible bulk load (bypasses WAL and memtable entirely).
This is safe only when no readers exist. Scale up after preload so all readers immediately
see the full dataset on first mount.

## Why 2TB dataset

With 16 × m5d.2xlarge instances (32GB RAM each), total fleet page cache capacity is ~512GB.
A 2TB dataset (4× fleet cache) ensures reads cannot be served from RAM — every request
that misses cache hits EBS. This is required to drive EBS IOPS toward the 256K ceiling.

## Preload performance

SST ingestion via `sst_generator.cc` (compiled on the writer, RocksDB headers already present):
- ~1.06M keys/sec sustained
- 2B keys × 1KB = ~2TB in ~32 min
- Ingested in batches of 100 SSTs to avoid file descriptor limits

## Load generator design

Each loader runs `wrk` with a Lua script that generates a new random key per HTTP request:
```lua
function request()
    local key = string.format("stress:%016d", math.random(0, num_keys - 1))
    return wrk.format("GET", "/get?key=" .. key)
end
```
This ensures random access across the full keyspace, forcing real EBS reads when the dataset
exceeds the fleet's combined OS page cache.

## Results recording

`04_run_stress.sh` writes a timestamped CSV to `stress-test/results/` on every interval:
```
elapsed_s,cluster_nodes,alb_rps,alb_p99_ms,alb_5xx,ebs_iops,ebs_mbs
30,16,185000,6.2,0,198000,792.1
60,16,187000,6.4,0,201000,804.0
...
```
Pass `--results-file /path/to/file.csv` to override the default path.

## Key Metrics Captured

- ALB RPS and p99 latency (CloudWatch `AWS/ApplicationELB`)
- EBS IOPS and throughput (CloudWatch `AWS/EBS`, 1-min granularity)
- Cluster node count (writer REST `/cluster/nodes`)

## Pass Criteria (IOPS saturation test)

| Metric | Expected |
|---|---|
| EBS IOPS | Approaches 256K ceiling |
| ALB 5xx errors | 0 |
| ALB p99 latency | Increases gracefully (higher ms, no errors) |
| Cluster nodes | 16/16 Online throughout |

## Observed Results (see [../docs/10-stress-testing.md](../docs/10-stress-testing.md) for full details)

| Test | Dataset | Loaders | RPS | p99 | EBS IOPS (steady) |
|---|---|---|---|---|---|
| Hot-key | 95GB | 10 × c5.4xlarge | ~315K | 20–35ms | ~0 (cached) |
| Random-key 1TB | 1TB | 20 × c5.4xlarge | ~140K | 4.7ms | ~78K sustained |
| IOPS saturation | 2TB | 60 × c5.4xlarge | TBD | TBD | TBD |

## Cost Warning

io2 Block Express at 256,000 IOPS on a 1TB volume: ~$125/hr.
16 × m5d.2xlarge cluster: ~$13/hr.
60 × c5.4xlarge spot loaders: ~$30/hr.
**Total: ~$168/hr. Tear down promptly after testing.**
