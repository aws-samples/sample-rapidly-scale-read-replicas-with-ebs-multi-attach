[← Troubleshooting](11-troubleshooting.md) · [Home](../README.md) · [Security →](13-security.md)

# 12. API Reference

Reference material: every REST endpoint, the SSM parameters, the file inventory, and the key design decisions with their rationale.

## REST endpoints

The C++ service (`rocksdb_service`) listens on **port 8080** on every node, in either `readwrite` (writer) or `readonly` (reader) mode set by `/etc/rocksdb/service.env`. All responses are JSON with `Connection: close`.

### Data plane

The ALB is a **read-only** data plane: it forwards `GET /get`, `GET /scan`, and `GET /health` to the fleet, but returns **`403` for the writer-only mutating endpoints** (`/put`, `/batch-put`, `/delete`, `/flush`) and for all `/admin/*`. Writes therefore only happen on-box against the writer via SSM — the LB never routes a mutation to a (possibly wrong) node.

#### `GET /get?key=<key>`
Read one key (URL-encoded). Works on any node; reachable through the ALB.

| Response | Meaning |
|---|---|
| `200 {"key":"...","value":"..."}` | Found |
| `404 {"error":"not found"}` | Missing |
| `400 {"error":"missing key"}` | No `key` param |
| `503 {"error":"db not ready"}` | DB not open yet |

#### `GET /scan?limit=<n>&after=<key>`
Return a **bounded page** of key/value pairs (sorted by key). Works on any node; reachable through the ALB.
- `limit` — max records to return; default **1000**, clamped to `[1, 10000]`.
- `after` — optional URL-encoded cursor (exclusive); pass the previous response's `next` to page forward.
- The response includes `next` (the last key of the page) **only when more records remain**; its absence means the scan is complete.
```json
{"records":[{"key":"k1","value":"v1"},{"key":"k2","value":"v2"}],"next":"k2"}
```
This caps per-request memory, response size, and IO — preventing unbounded full-table dumps and `/scan`-flood DoS. To read everything, page with `after` until `next` is absent.

#### `POST /put`  — writer only
```json
{"key":"hello","value":"world"}
```
Writes one pair and auto-flushes (async) so readers catch up within ~10 ms. `403 {"error":"read-only instance"}` if sent to a reader. **The ALB returns `403` for `/put`** — it's reachable only on-box (SSM → writer).

#### `POST /delete`  — writer only
```json
{"key":"hello"}
```
Deletes one key and auto-flushes. `403` on readers. **ALB returns `403`** — on-box only.

#### `POST /batch-put`  — writer only
```json
{"pairs":[{"key":"k1","value":"v1"}, ...]}   // up to 1000 pairs
```
Writes a batch as one RocksDB `WriteBatch`. Returns `{"status":"ok","written":N}`. Used by the stress preloader. **ALB returns `403`** — on-box only.

#### `POST /flush`  — writer only
Forces a synchronous flush. Rarely needed (writes auto-flush). **ALB returns `403`** — on-box only.

### Health & cluster info

#### `GET /health`
| Response | Meaning |
|---|---|
| `200 {"status":"ok","mode":"readwrite"}` | Writer, DB open |
| `200 {"status":"ok","mode":"readonly"}` | Reader, DB open |
| `503 {"status":"starting","mode":"..."}` | DB not open yet |

Used by the ALB health check and the TUI's "Svc Health".

#### `GET /cluster/nodes` — requires bearer token
Count + IPs of Online Corosync nodes (from `pcs status nodes corosync`). Requires `Authorization: Bearer <token>` (exposes internal topology); `403` without it.
```json
{"online":3,"nodes":["10.0.0.1","10.0.0.2","10.0.0.3"]}
```

#### `GET /cluster/nodeids` — requires bearer token
Map of private IP → Corosync node ID (from `corosync.conf`). Used to resolve a node ID to an instance. Requires `Authorization: Bearer <token>`; `403` without it.
```json
{"map":{"10.0.0.1":1,"10.0.0.2":2,"10.0.0.3":3}}
```

### Admin / lifecycle

All `/admin/*` endpoints — and the `/cluster/*` info endpoints above — require an `Authorization: Bearer <token>` header and return **`403`** without a valid token (the service fails closed — see [RocksDB & the REST Service](05-rocksdb-service.md) and [Security](13-security.md)). The token is the SSM `admin-token` SecureString, read on-box from `/etc/rocksdb/service.env`. The **ALB also returns `403` for any `/admin/*` path regardless of token**, so these endpoints are only ever reachable on-box via SSM.

| Endpoint | Method | Effect |
|---|---|---|
| `/admin/promote` | POST | Update SSM writer-id, switch to `readwrite`, remove `LOCK`, restart (detached). → `{"action":"promoting"}` |
| `/admin/demote` | POST | Switch to `readonly`, restart (detached). → `{"action":"demoting"}` |
| `/admin/bootstrap` | POST | Writerless recovery: wipe stale state, build a fresh single-node cluster, become writer. Body: `priv_ip`, `instance_id`, `region`, `volume_id`, `cluster_name` — each field is **validated** (only `[A-Za-z0-9._-]`, length-capped) before use in a shell script, closing a shell-injection vector. |
| `/admin/start-watcher` | POST | Enable + start `cluster-watcher.service` (used after a promote). |
| `/admin/leave-cluster` | POST | Stand by and stop Pacemaker/Corosync gracefully. |
| `/admin/dbsize` | GET | `{"bytes":N}` total SST size (instant, via `rocksdb.total-sst-files-size`). |
| `/admin/resetdb` | POST | Writer only. Close DB, delete `db/*`, recreate, reopen. **All data lost.** |

## SSM Parameters

All under the `/rocksdb-cluster/` prefix.

| Parameter | Type | Set by | Read by | Purpose |
|---|---|---|---|---|
| `volume-id` | String | CDK at deploy | Every instance on boot | Which EBS volume to self-attach |
| `corosync-authkey` | SecureString | Writer on first setup | Every reader on boot | Corosync auth key (base64). **Empty ⇒ no cluster ⇒ become writer.** |
| `pacemaker-authkey` | SecureString | Writer on first setup | Every reader on boot | Pacemaker auth key (base64) |
| `hacluster-password` | SecureString | Writer on first setup | Every reader on boot | Password for the `hacluster` user used by `pcsd` peer authentication |
| `admin-token` | SecureString | Writer on first setup | Every node on boot | Bearer token gating all `/admin/*` endpoints |
| `writer-instance-id` | String | Writer; updated on promote | Booting instances | Who the current writer is (writer-election + promote) |

Lifecycle: `volume-id` is created/destroyed with the stack; the auth keys, `hacluster-password`, and `admin-token` are written by the writer at first setup; `writer-instance-id` is updated on every promote. Because the runtime-created parameters aren't CloudFormation-managed, `destroy.sh` explicitly deletes `corosync-authkey`, `pacemaker-authkey`, `hacluster-password`, `admin-token`, and `writer-instance-id` on teardown (see [Operations](07-operations.md#teardown)).

## File inventory

### Infrastructure & app
| File | Purpose |
|---|---|
| `app.py` | CDK app entry point |
| `rocksdb_stack.py` | CDK stack + instance boot script (writer/reader election) |
| `tui.py` | Terminal dashboard / cluster manager |
| `deploy.sh` / `destroy.sh` | `cdk deploy --all` / `cdk destroy --all --force` |
| `ami_id.txt` | ID of the AMI the stack deploys |

### On-instance (baked into the AMI) — `scripts/`
| File | Purpose |
|---|---|
| `build_ami.sh` | AMI build orchestrator |
| `setup_phase1.sh` | AMI phase 1: install packages, hold kernel, reboot |
| `setup_phase2.sh` | AMI phase 2: compile RocksDB, install services, auto-reboot hardening |
| `rocksdb_service.cc` | C++ REST service wrapping RocksDB |
| `cluster_watcher.sh` | Writer-side node add/remove daemon |
| `cluster_self_remove.sh` | Shutdown hook: leave the cluster cleanly |
| `cluster_key_sync.sh` | Reader-side: refresh auth keys from SSM |
| `fence_aws_wrapper.sh` | STONITH agent wrapper (handles already-dead nodes) |
| `promote_reader.sh` | Promote a reader to writer via REST |
| `setup_cluster.sh` | Recovery: rebuild the cluster from scratch |

### Test harness — `test/` (mirrors the TUI; see [Testing](09-testing.md))
| File | Purpose |
|---|---|
| `common.sh` | Shared helpers: discovery, `wait_for_cluster_nodes`, `resolve_node`, assertions |
| `scale.sh` | TUI `scale` |
| `promote.sh` | TUI `promote` (graceful) |
| `kill.sh` | TUI `kill` + recovery wait |
| `write.sh` / `read.sh` / `scan.sh` / `delete.sh` | TUI data commands |
| `run_custom_sequence.sh` | End-to-end orchestrator (all seven commands + the back-to-back-kill regression) |
| `archive/` | Superseded scripts kept for reference |

### Stress test — `stress-test/`
| File | Purpose |
|---|---|
| `sst_generator.cc` | Direct SST bulk-loader |
| `01_preload_data.sh` … `05_teardown.sh` | Preload, scale, launch loaders, monitor, teardown |

## Design decisions

| Decision | Rationale |
|---|---|
| Dedicated VPC | Clean isolation and predictable, complete `cdk destroy` |
| io2 Block Express, 1000 GiB, 256K IOPS | Only tier that supports Multi-Attach at the performance a 16-node fleet can use |
| `/health` returns 503 before DB open | ALB gates traffic automatically — no node serves before it's ready |
| Auto-flush on write/delete | Readers catch up within ~10 ms without a manual flush |
| Thread-per-connection HTTP server | Zero dependencies; ~16K RPS/node is sufficient |
| 16 GFS2 journals pre-created | New readers mount immediately, no reformat |
| Ubuntu 24.04 | Only distro shipping the full GFS2/Pacemaker stack in default repos |
| No ASG lifecycle hook | Removed — caused termination deadlocks; journal recovery handles it |
| `no-quorum-policy=freeze` | Freezes resources if quorum is lost (a minority partition must never act independently on the shared disk); kept correct during scaling by LMS + the watcher pinning `expected_votes` to the live count |
| Last Man Standing (`last_man_standing`) | Set in corosync.conf before first start; lowers `expected_votes` to live members on shrink. With the watcher pinning `expected_votes` to the live count, prevents leftover conf ghosts from inflating quorum → DLM `kern_stop` freeze |
| Monotonic node IDs | Avoids the Corosync knet ID-reuse election bug |
| Auto-reboot disabled in AMI | Prevents unattended-upgrades reboots that cause membership churn; patch by AMI rebuild |
| Writer scale-in protection | ASG must never terminate the writer during scale-down |
| Bearer-token auth on `/admin/*` | Lifecycle/admin endpoints fail closed without a valid SSM-issued token; the **read** data plane (`/get`, `/scan`, `/health`) stays open for the ALB. See [Security](13-security.md) |
| Security group: 8080 ALB-only, SSH closed | Port 8080 reachable only from the ALB; no public SSH (operators use SSM Session Manager); cluster traffic restricted to fellow members |
| ALB is a read-only data plane | The ALB returns `403` for `/admin/*` **and** for the writer-only mutating endpoints (`/put`, `/batch-put`, `/delete`, `/flush`). Because the LB load-balances across all nodes, a forwarded write could land on the writer — and on a single-node cluster the writer is the only target, making it a 100% reachable unauthenticated write path. Blocking them keeps the public plane read-only; writes go on-box (SSM → writer) |
| `/cluster/*` token-gated | `/cluster/nodes` and `/cluster/nodeids` expose internal IPs/node IDs, so they require the bearer token like `/admin/*` |
| EBS encryption at rest | The io2 data volume is `encrypted=True` (KMS); the single shared copy of the data is encrypted at rest |
| Least-privilege IAM | Inline policy scoped to `/rocksdb-cluster/*` SSM, KMS via-ssm, EC2 `instance/*`+`volume/*`; only `autoscaling:*` stays `*` |
| ALB access logs to S3 | Request-level audit trail (source IP, path, status) for the unauthenticated data plane |
| Bounded `/scan` + request caps | `/scan` paginates (`limit`/`after`); `Content-Length` validated, 64 MiB max request, 1,000-pair `/batch-put` cap — prevent crash/OOM/scan-flood DoS |
| No WAF on the ALB | A rate-based WAF was removed so the demo stays load/stress-testable from a few loader IPs; re-add for production (see [Security](13-security.md)) |
| IMDSv2 + hop limit 1 | Enforced on the launch template to mitigate SSRF credential theft |
| Corosync `token=30000` | Raised from 10 s; prevents token loss at 16 nodes that hung reloads and could collapse quorum (see [Cluster Stack](04-cluster-stack.md#corosync--membership-and-messaging)) |

---
Next: [Security →](13-security.md)
