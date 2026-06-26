[← RocksDB & Service](05-rocksdb-service.md) · [Home](../README.md) · [Operations →](07-operations.md)

# 6. Components & Code

A file-by-file tour of the codebase, plus how the machine image (AMI) is built and how an instance decides whether to become a writer or a reader on boot.

## Repository map

```
/
├── app.py                     # CDK app entry point
├── rocksdb_stack.py           # CDK stack + the instance boot script (userdata)
├── tui.py                     # Terminal dashboard / cluster manager
├── deploy.sh / destroy.sh     # CDK deploy / destroy wrappers
├── ami_id.txt                 # ID of the most recently built AMI (read by the stack)
├── scripts/
│   ├── build_ami.sh           # Orchestrates building the AMI
│   ├── setup_phase1.sh        # AMI build phase 1: install packages, then reboot
│   ├── setup_phase2.sh        # AMI build phase 2: compile RocksDB, install services + hardening
│   ├── rocksdb_service.cc     # The C++ REST service (see chapter 5)
│   ├── cluster_watcher.sh     # Writer-side daemon that adds/removes cluster nodes
│   ├── cluster_self_remove.sh # Shutdown hook: leave the cluster cleanly
│   ├── cluster_key_sync.sh    # Reader-side: refresh auth keys from SSM
│   ├── fence_aws_wrapper.sh   # STONITH agent wrapper (handles already-dead nodes)
│   ├── promote_reader.sh      # Promote a reader to writer via REST
│   └── setup_cluster.sh       # Recovery: rebuild the whole cluster from scratch
├── test/                      # Functional test harness (chapter 9)
├── stress-test/               # Load-test suite (chapter 10)
└── docs/                      # This documentation
```

## Infrastructure as code

### `rocksdb_stack.py` (CDK)

Defines the entire AWS footprint and the instance boot logic. Key parts:

- **VPC** — dedicated, two public subnets (an ALB needs two AZs), no NAT gateway. Compute and the volume are pinned to a single AZ.
- **io2 Multi-Attach volume** — 1,000 GiB, 256,000 IOPS, **encrypted at rest** (`encrypted=True`, account-default EBS KMS key); the volume ID is published to SSM so instances can self-attach.
- **Launch Template** — `m5d.2xlarge`, the custom AMI (from `ami_id.txt`), the security group, IAM role, and the userdata boot script. Enforces **IMDSv2** with `http_put_response_hop_limit=1` (mitigates SSRF credential theft).
- **Security group** — port 8080 reachable **only from the ALB security group**; SSH (22) **closed to the internet** (operators use SSM Session Manager; optional break-glass via the `admin_ssh_cidr` CDK context); cluster/Corosync traffic restricted to fellow cluster members via a self-referencing rule (not the whole VPC CIDR).
- **Auto Scaling Group** — min 1, max 16, desired 1. Desired capacity *is* the cluster size.
- **Application Load Balancer + target group** — port 80 → 8080, health check `GET /health` (15 s interval, healthy after 2, unhealthy after 3). It's a **read-only data plane**: listener rules return **HTTP 403 for any `/admin/*` path and for the writer-only endpoints** (`/put`, `/batch-put`, `/delete`, `/flush`), so only `/get`, `/scan`, and `/health` are served. **Access logs** are written to a dedicated S3 bucket. No WAF (see [Security](13-security.md)).
- **IAM role** — permissions to attach/detach the volume, create/delete tags, set instance protection, call `fence_aws`'s EC2 actions, and read/write SSM + KMS. Also attaches the **`AmazonSSMManagedInstanceCore`** managed policy so the SSM agent registers and operators can use Session Manager / Run Command instead of SSH. The inline policy is **scoped to least privilege**: SSM to `/rocksdb-cluster/*` parameters, KMS only `via ssm`, and EC2 mutations to `instance/*`+`volume/*` in this account/region. Only the `autoscaling:*` actions remain `resources="*"` (the ASG ARN is created after the role; `Describe*` needs `*`) — see [Security](13-security.md).
- **`RemovalPolicy.DESTROY`** on resources so `destroy.sh` cleans up fully.

The AMI is selected by reading `ami_id.txt`:

```python
machine_image = ec2.MachineImage.generic_linux({region: ami_id})  # if ami_id.txt exists
```

### The boot script (userdata) — writer vs reader election

The same userdata runs on every instance. It decides the node's role like this:

```
on boot:
  wait for AWS CLI + IAM credentials
  read volume-id from SSM, self-attach the EBS volume, wait for the device

  read /rocksdb-cluster/corosync-authkey from SSM
  if no auth key exists:
        → no cluster yet      → BECOME WRITER
  else:
        check writer-instance-id (SSM) and the RocksDB-Writer EC2 tag
        if a writer is already running   → BECOME READER
        if the recorded writer is gone   → BECOME WRITER (take over)
```

**As a writer**, it: tags itself `rocksdb-role=writer`, sets ASG scale-in protection (so the ASG never terminates the writer), records its instance ID in SSM, sets up a single-node Pacemaker/Corosync cluster (enabling **Last Man Standing** in `corosync.conf` before the first start — see [Cluster Stack](04-cluster-stack.md#enabling-last-man-standing-at-setup-implementation-detail)), formats GFS2 (only if not already formatted — data is preserved), creates the DLM + GFS2 resources and fencing, stores the auth keys in SSM, **generates the 32-byte admin token (if absent) and stores it in SSM as `/rocksdb-cluster/admin-token` (SecureString)**, and starts `rocksdb.service` (read-write) + `cluster-watcher.service`.

**As a reader**, it: wipes any stale cluster config, fetches the auth keys from SSM, tags itself `rocksdb-role=reader` and `rocksdb-join=rocksdb-cluster` (the signal the watcher waits for), and starts `rocksdb.service` (read-only). The writer's watcher does the actual joining.

Both roles fetch the admin token from SSM and write it as `ADMIN_TOKEN` into `/etc/rocksdb/service.env`, so every node's service can authenticate `/admin/*` requests without the secret ever leaving the instance (see [Security](13-security.md)).

This election logic is why recycling the writer works: terminate it, and the replacement boots, sees the recorded writer is gone, and takes over — with the data intact on the shared volume.

## On-instance software (baked into the AMI)

| File (installed path) | What it is |
|---|---|
| `rocksdb_service` (`/usr/local/bin/`) | The REST service (chapter 5). Run by `rocksdb.service`. |
| `cluster_watcher.sh` (`/usr/local/bin/`) | Writer-side membership reconciler (chapter 4). Run by `cluster-watcher.service`. |
| `cluster_self_remove.sh` (`/usr/local/bin/`) | Shutdown hook to leave the cluster cleanly (chapter 4). Run by `cluster-self-remove.service` on stop. |
| `cluster_key_sync.sh` (`/usr/local/bin/`) | Reader-side auth-key refresher. Run by `cluster-key-sync.timer` every 10 s. |
| `fence_aws` (`/usr/sbin/`, wrapper) | STONITH agent that handles already-terminated instances (chapter 4). |

### systemd units

| Unit | Type | Role |
|---|---|---|
| `rocksdb.service` | always-restart | Runs the REST service; `ExecStartPre` waits until GFS2 is mounted and `db/` exists. |
| `cluster-watcher.service` | always-restart | Runs the watcher (only meaningful on the writer). |
| `cluster-self-remove.service` | oneshot (on stop) | Leaves the cluster cleanly at shutdown. |
| `cluster-key-sync.timer` | timer (10 s) | Readers refresh auth keys from SSM. |
| `corosync.service` | restart on-failure | Restarts only if it crashes — never when stopped cleanly by `pcs`. |

## The AMI build pipeline

Building the AMI is a one-time (~16 min) step that bakes everything above into a reusable image, so instances boot ready to run.

`scripts/build_ami.sh` orchestrates it:

1. Launches a temporary `c5.9xlarge` builder from the latest Ubuntu 24.04 base AMI.
2. Copies the scripts up and runs **phase 1** (`setup_phase1.sh`):
   - Installs the GFS2/Pacemaker stack and build tools. Only the AWS fence agent (`fence-agents-aws`) is installed — not the full `fence-agents` meta-package — since the fleet fences exclusively via `fence_aws`; this avoids the other clouds' agents and their heavy Python SDKs.
   - Disables things that cause surprise reboots (removes `unattended-upgrades`, disables `needrestart`, holds the kernel).
   - Reboots to load the new kernel modules cleanly.
3. Runs **phase 2** (`setup_phase2.sh`):
   - Compiles RocksDB 9.7.4 from source (with Snappy/zlib/lz4/zstd) and the REST service.
   - Installs all the systemd units and scripts above; loads the `dlm`/`gfs2` kernel modules.
   - Replaces `fence_aws` with the wrapper.
   - **Hardens against auto-reboots** (added after the unattended-upgrades incident — see [Troubleshooting](11-troubleshooting.md)): masks the `apt-daily` timers and `unattended-upgrades`, disables cloud-init package updates, and pins `Unattended-Upgrade::Automatic-Reboot "false"`.
4. Stops the builder, creates the AMI, terminates the builder, and writes the new AMI ID to `ami_id.txt`.

> **Why the hardening matters:** a fresh reader that auto-reboots mid-join leaves and rejoins the Corosync ring, which looks like instability. Baking in "no automatic reboots" keeps the fleet deterministic. Patching is handled by rebuilding the AMI and recycling nodes (immutable-infrastructure model), which is the recommended posture for cluster nodes.

## Operator tooling

| File | Chapter |
|---|---|
| `tui.py` — the terminal dashboard and command interface (drives nodes over SSM Run Command) | [The TUI](08-tui.md) |
| `test/` — functional test harness mirroring the TUI commands (over SSM) | [Testing](09-testing.md) |
| `stress-test/` — load generators and the SST preloader | [Stress Testing](10-stress-testing.md) |
| `deploy.sh` / `destroy.sh` — `cdk deploy --all` / `cdk destroy --all --force` wrappers | [Operations](07-operations.md) |

---
Next: [Operations →](07-operations.md)
