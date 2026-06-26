[← Cluster Stack](04-cluster-stack.md) · [Home](../README.md) · [Components →](06-components.md)

# 5. RocksDB & the REST Service

The bottom three layers give us one disk, safely shared, with a coherent filesystem. This layer is the database itself and the thin HTTP server that exposes it.

## RocksDB primary and secondary instances

RocksDB has a built-in capability that this whole architecture hinges on: **secondary instances**.

| Mode | Opened with | Can write? | Holds the LOCK? | Used by |
|---|---|---|---|---|
| **Primary** | `DB::Open()` | Yes | Yes (exclusive) | the writer |
| **Secondary** | `DB::OpenAsSecondary()` | No | No | every reader |

A primary is the normal full-control RocksDB. A **secondary** opens the *same database directory* in a follower mode: it reads the data files but never takes the exclusive write lock, so many secondaries can open the same directory at once. This is what lets 15 readers open the writer's database simultaneously.

### How a reader stays current: the catch-up loop

A secondary doesn't automatically see new data — it has to be told to look. The service runs a background thread that calls `TryCatchUpWithPrimary()` every **10 milliseconds**:

```cpp
static void catch_up_thread() {
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        if (g_db) g_db->TryCatchUpWithPrimary();
    }
}
```

Each catch-up does two things:

1. **Re-reads the MANIFEST** — RocksDB's log of which SST files make up the database — so it discovers SST files the writer has newly flushed.
2. **Replays new WAL entries** — so it even sees writes the writer hasn't flushed to an SST file yet.

Because all of this is reading the *same files on the shared GFS2 volume*, there is no data transfer over the network — the reader is just re-reading a directory it already has mounted. End-to-end staleness is ~10 ms.

### How the writer makes new data visible quickly

On the writer side, every `/put` and `/delete` triggers an **asynchronous flush** (`FlushOptions.wait = false`). Flushing turns the in-memory memtable into an SST file on disk promptly, so secondaries pick it up on their next catch-up rather than waiting for RocksDB's normal flush schedule. The write returns to the client without blocking on the flush.

### Startup ordering

- The **writer** opens with `DB::Open()` immediately.
- A **reader** first waits for the primary database to exist (polls for `<db>/CURRENT`), then opens with `OpenAsSecondary()` (using a small private scratch directory under `/tmp` for its own bookkeeping), does an initial catch-up, and starts the catch-up thread.

This is why a reader's `/health` returns `503` until the writer has created the database — the ALB won't route to it yet.

## The REST service (`rocksdb_service.cc`)

The service is a single, dependency-free C++ program (~400 lines). It deliberately avoids any HTTP framework: a plain socket, a thread per connection, and minimal hand-rolled JSON. That keeps the AMI simple and is more than fast enough — it sustains ~16,000 requests/sec per node.

```
./rocksdb_service <db_path> <readwrite|readonly> [port]
        e.g.  /usr/local/bin/rocksdb_service /data/rocksdb/db readwrite 8080
```

- The **mode** argument (`readwrite`/`readonly`) decides primary vs secondary. It comes from `/etc/rocksdb/service.env`, which systemd reads.
- The same binary runs on every node; only the mode differs. Promotion/demotion is just changing that mode and restarting.

### Design choices

| Choice | Why |
|---|---|
| No HTTP library, thread-per-connection | Zero dependencies, trivial to build into the AMI; ~16K RPS/node is plenty. |
| `/health` returns `503` until DB open | The ALB uses `/health`; a node is invisible to traffic until truly ready. |
| Auto-flush on write/delete | Readers catch up within ~10 ms without any manual flush step. |
| `Connection: close` responses | Avoids keep-alive reuse issues with the minimal server. |
| Mode in an env file | Promote/demote = edit the file + restart; no rebuild, no redeploy. |

## The HTTP API at a glance

Full details, request/response shapes, and status codes are in the [API Reference](12-api-reference.md). Grouped by purpose:

**Data plane**
| Endpoint | Who | Purpose |
|---|---|---|
| `GET /get?key=` | any node | Read one key. |
| `GET /scan?limit=&after=` | any node | Return a bounded page of key/value pairs (default 1,000, max 10,000; page with `after`). |
| `POST /put` | writer only | Write one key (auto-flush). |
| `POST /delete` | writer only | Delete one key (auto-flush). |
| `POST /batch-put` | writer only | Write up to 1,000 pairs in one batch (used by the stress preloader). |
| `POST /flush` | writer only | Force a synchronous flush (rarely needed). |

A write sent to a reader returns `403 read-only instance` — the role is enforced in the service, not just by convention. The **ALB only forwards the read endpoints** (`/get`, `/scan`, `/health`); it returns `403` for the writer-only endpoints (`/put`, `/delete`, `/batch-put`, `/flush`) and `/admin/*`, so writes are only ever driven on-box against the writer via SSM.

**Health & cluster info**
| Endpoint | Purpose |
|---|---|
| `GET /health` | `{"status":"ok","mode":"readwrite|readonly"}`, or `503` while starting. The ALB health check and the TUI both use this. **Not** token-gated. |
| `GET /cluster/nodes` | Count + IPs of Online Corosync nodes (parsed from `pcs status`). **Requires the bearer token** (exposes internal topology). |
| `GET /cluster/nodeids` | Map of private IP → Corosync node ID (from `corosync.conf`). **Requires the bearer token**. |

**Admin / lifecycle**

All `/admin/*` endpoints — and the `/cluster/*` info endpoints above — require an `Authorization: Bearer <token>` header. The token is a 32-byte random secret generated by the first node and stored in SSM Parameter Store as a SecureString at `/rocksdb-cluster/admin-token`, written into `/etc/rocksdb/service.env` as `ADMIN_TOKEN`. The service verifies it with a constant-time compare and **fails closed** — any gated request is rejected with `403` if no token is configured or the token doesn't match. `/health` and the data endpoints (`/get`, `/scan`, `/put`, `/delete`, `/batch-put`, `/flush`) are **not** token-gated. (The ALB returns `403` for `/admin/*` **and** for the writer-only endpoints `/put`/`/batch-put`/`/delete`/`/flush`, so admin and writes are only ever invoked on-box via SSM — only reads traverse the ALB; see [Security](13-security.md).)

| Endpoint | Purpose |
|---|---|
| `POST /admin/promote` | Become the writer: update SSM writer-id, switch mode to `readwrite`, remove the RocksDB `LOCK`, restart the service. |
| `POST /admin/demote` | Become a reader: switch mode to `readonly`, restart. |
| `POST /admin/bootstrap` | Writerless recovery: build a fresh single-node cluster on this reader and become writer. |
| `POST /admin/start-watcher` | Start the cluster watcher (used right after a promote). |
| `POST /admin/leave-cluster` | Gracefully stand by and leave the cluster. |
| `POST /admin/resetdb` | Wipe the database (writer only). |
| `GET /admin/dbsize` | Total SST size in bytes (instant, via a RocksDB property). |

### Promote / demote, mechanically

Promotion has to survive the service restarting itself, so it's done carefully:

1. `POST /admin/promote` immediately writes the new writer's instance ID to SSM (so any instance booting at that moment won't also try to become writer).
2. It flips `MODE=readonly` → `readwrite` in `service.env` and deletes the RocksDB `LOCK` file.
3. It restarts `rocksdb.service` via `systemd-run` in a **detached** transient unit — so the restart isn't killed when the current service process dies.
4. The node reopens RocksDB with `DB::Open()` (primary) and starts serving writes.

Demotion is the mirror image (flip to `readonly`, restart). The orchestration of "demote the old writer, then promote the new one" is done by the TUI / `promote_reader.sh` — see [Operations](07-operations.md#promote-failover).

---
Next: [Components & Code →](06-components.md)
