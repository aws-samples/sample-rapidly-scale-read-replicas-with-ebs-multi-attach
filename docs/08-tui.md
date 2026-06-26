[← Operations](07-operations.md) · [Home](../README.md) · [Testing →](09-testing.md)

# 8. The TUI

## What it is

`tui.py` is a **terminal dashboard and control panel** for the whole cluster, built with [Textual](https://textual.textualize.io/). It is the primary way a human operates the system: it shows live cluster state and lets you run every operation — scale, promote, kill, and read/write data — by typing a command, without touching the AWS console or SSH.

Think of it as "mission control": one screen that answers *what is the cluster doing right now?* and *let me change it.*

```bash
./tui.sh
```

It talks to the same things you would by hand:
- the **AWS APIs** (CloudFormation for stack outputs, EC2/ASG for instances, CloudWatch for metrics) via `boto3`, and
- each node's **REST service** on `:8080`, reached via **SSM Run Command** to `http://localhost:8080` on the target node (`/health`, `/cluster/nodes`, `/get`, `/put`, etc.) — port 8080 isn't publicly reachable, so the TUI never hits a node's IP directly. Admin actions (promote/demote/etc.) require the on-box bearer token, which the TUI supplies automatically by reading the node's own `/etc/rocksdb/service.env`. No SSH key is needed.
- the **ALB** on port 80 for the two node-agnostic data commands (`read <key>` and bare `scan`): these make a **real HTTP call** to the load balancer — the same path a production client uses — instead of going node-by-node through SSM, so they skip the SSM round-trip and are noticeably faster.

It is **read-mostly and safe to leave open** — it refreshes AWS data every 10 seconds and only changes anything when you type a command.

## What the screen shows

```
┌ rocksdb cluster manager ─────────────────── region: us-east-1 · alb … asg … ┐
├ nodes   1 writer / 4 readers / 5 total ────────────────────┬─ live metric ──┤
│ Role    Instance ID    Private IP   Public IP   Svc  ASG    │   graph        │
│ writer  i-0abc…        10.0.0.10    54.x.x.x    ok   InSvc 1 │  (ALB rps,     │
│ reader  i-0def…        10.0.0.11    54.x.x.x    ok   InSvc 6 │   p99, EBS     │
│ …                                                            │   iops, …)     │
├ ebs volume ──────────────┬ metrics · 60s window ────────────────────────────┤
│ vol id   vol-0…          │ alb rps  alb p99  ebs iops  ebs mb/s  db size     │
│ type io2  state in-use   │  …        …        …          …        …          │
│ size 1000 GiB            ├ output ──────────────────────────────────────────┤
│ prov iops 256,000        │ 12:00:01  scaling to 5…                           │
│ throughput …             │ 12:03:40  ✓ scale to 5 complete                   │
│                          │ ❯ _                                               │
└──────────────────────────┴──────────────────────────────────────────────────┘
  12:03:42   last refresh: 12:03:40   · auto every 10s
```

| Panel | Shows |
|---|---|
| **Header** | Title, AWS region, ALB DNS, and ASG name. |
| **Nodes table** | One row per instance: role (writer/reader), instance ID, private/public IP, **Svc Health** (`/health` status), **ASG Lifecycle** (InService/Pending/Terminating), and the Corosync **Node ID**. The header tallies writers/readers/total. |
| **EBS volume** | Volume ID, type, state, size, provisioned IOPS, throughput. |
| **Live metric graph** | An ASCII time-series of one metric; cycle through ALB RPS, ALB p99 latency, EBS IOPS, EBS MB/s, and DB size. |
| **Metrics row** | Current values for ALB RPS, ALB p99, EBS IOPS, EBS MB/s, and DB size (from CloudWatch + the writer). |
| **Output log** | Timestamped results of your commands. |
| **Command input** | Where you type commands (the `❯` prompt). |
| **Status bar** | Clock and last-refresh time. |

"Svc Health = ok" for a node means its `GET /health` returned `200`. This is the same signal the ALB uses to decide whether to route traffic, and the same signal the test harness waits on.

## Commands

Type these at the `❯` prompt.

| Command | What it does | Maps to |
|---|---|---|
| `scale <count>` | Scale the cluster to 1–16 nodes | ASG desired capacity + watcher |
| `promote <node>` | Promote a reader to writer (old writer demotes in place) | `/admin/demote` → `/admin/promote` |
| `kill <node>` | Terminate a node (ASG replaces it) | `ec2:TerminateInstances` |
| `write <key> <value>` | Write a key to the writer | `POST /put` (SSM → writer) |
| `read <key>` | Read a key via the ALB (load-balanced across any node) | `GET /get?key=` through the ALB |
| `read <node> <key>` | Read a key from a specific node | `GET /get?key=` (SSM → node) |
| `scan` | List records via the ALB (load-balanced across any node) | `GET /scan` through the ALB |
| `scan <node>` | List all records from a specific node | `GET /scan` (SSM → node) |
| `delete <key>` | Delete a key from the writer | `POST /delete` (SSM → writer) |
| `resetdb` | Wipe the entire database (writer only) | `POST /admin/resetdb` |
| `stress-test <size> <loaders> <mins>` | Run the load-test suite | see [Stress Testing](10-stress-testing.md) |
| `help` | List commands | — |
| `quit` / `exit` | Leave the TUI | — |

### Referring to a node

Commands that take a `<node>` accept any of:
- the **Corosync node ID** (the integer in the Node ID column), e.g. `read 6 hello`
- the node's **public IP**
- the node's **private IP**

(`scan 1` scans node ID 1, which is the writer.) This resolution logic is mirrored exactly by the test harness's `resolve_node` helper.

Omitting the node entirely — `read <key>` or a bare `scan` — sends the request to the **ALB** instead, which load-balances it across the whole fleet (any healthy node serves reads). Use the node-specific form when you need to inspect or verify one particular replica (e.g. confirm a reader has caught up); use the node-agnostic form for a quick, fast read the way a real client would. Note that an ALB read may land on a reader that is ~10 ms behind the writer, so a `read <key>` immediately after a `write` can occasionally return a slightly stale value — read against the writer's node ID if you need read-your-write certainty.

### Keyboard shortcuts

| Key | Action |
|---|---|
| `F1` or `/` | Focus the command input |
| `m` / `n` | Cycle the metric graph forward / backward |
| `Ctrl+R` | Force an immediate refresh |
| `Ctrl+Q` / `Ctrl+C` | Quit |

## A typical session

```
scale 5                 # grow to 1 writer + 4 readers; watch the nodes table fill in
write user:1 Alice      # write to the writer
read 1 user:1           # read it back from the writer (node 1)
read user:1             # read it back via the ALB (any node, real client path)
scan 3                  # confirm a reader (node 3) sees the same data (replication)
promote 3               # make node 3 the writer; node 1 becomes a reader
write user:2 Bob        # write to the new writer
kill 4                  # terminate a reader; watch the ASG replace it and rejoin
delete user:1           # delete a key
scale 1                 # shrink back to just the writer
```

The output log shows progress for long operations (e.g. scale prints `asg InService` and `cluster online` counts as nodes join), and the nodes table reflects the new state on the next refresh.

## How it relates to the test harness

Because the TUI *is* the canonical interface, the functional tests are written to do **exactly what the TUI does** for each command (same AWS calls, same REST endpoints, same readiness definition). That alignment is the whole point of the harness — see [Testing](09-testing.md).

---
Next: [Testing →](09-testing.md)
