[← Components](06-components.md) · [Home](../README.md) · [The TUI →](08-tui.md)

# 7. Operations

How to set the system up, run it day to day, and recover it. The TUI is the easiest interface ([next chapter](08-tui.md)); every operation also has a shell/`curl`/AWS-CLI equivalent for automation.

## Prerequisites

- An AWS account with CDK bootstrapped (`cdk bootstrap`) and credentials configured.
- Python 3.11+ with the [`uv`](https://docs.astral.sh/uv/) package manager.
- Node.js 20+ (for CDK).

No manual key-pair setup is needed — the build script creates the `rocksdb-key` key pair automatically.

> **Node access is via AWS SSM, not SSH.** Port 22 is closed to the internet; operators reach instances through **SSM Session Manager** (`aws ssm start-session`) and the tooling drives nodes via **SSM Run Command** (hitting `http://localhost:8080` on the target node). No SSH key is needed. An optional break-glass SSH CIDR can be opened via the `admin_ssh_cidr` CDK context. See [Security](13-security.md).

## First-time setup

### 1. Build the AMI (~16 min, one-time)

```bash
./scripts/build_ami.sh
```

Builds the image (chapter 6) and writes its ID to `ami_id.txt`. You only repeat this when you change on-instance code (the service, scripts, systemd units) or want to refresh the OS.

> **Deploy on a freshly built AMI.** A stale image can carry a pending OS/kernel update that a node applies and reboots for on first boot, interrupting the writer's cluster bootstrap. Rebuilding bakes in the current kernel so there's nothing pending. If reusing an older AMI, first verify a test instance shows no `/var/run/reboot-required` and no `linux-image` in `apt list --upgradable`. (See [Troubleshooting](11-troubleshooting.md#the-big-one-surprise-reboots-cause-membership-churn).)

### 2. Deploy the stack (~3 min)

```bash
./deploy.sh          # = uv run cdk deploy --all --require-approval never
```

Creates the VPC, ASG (desired = 1), ALB, the io2 Multi-Attach volume, IAM role, and security groups.

### 3. Wait for the writer to self-configure (~2 min)

The first instance boots, finds no cluster, and makes itself the writer: single-node cluster, GFS2 format, DLM/GFS2 resources, fencing, starts the service read-write, stores auth keys in SSM. When `GET http://<writer-ip>:8080/health` returns `{"status":"ok","mode":"readwrite"}`, it's ready.

### 4. Operate it

```bash
uv run python tui.py
```

## Day-2 operations

### Scale (add/remove readers)

Scaling is just setting the ASG desired capacity; the writer's watcher does the cluster wiring.

```bash
# TUI:   scale 8
# Shell:
ASG=$(aws cloudformation describe-stacks --stack-name RocksDbStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ASGName`].OutputValue' --output text)
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" --desired-capacity 8
```

- **Scale up:** new instances boot, attach the volume, tag `rocksdb-join`; the watcher adds them **one at a time**; each starts serving once GFS2 is mounted and `/health` is `ok`. A full **1→16 takes ~14 min end-to-end** (measured ~13m43s, command → all 16 serving): ~3 min for the ASG to launch+boot the 15 instances, then a steady **~40 s/node** as the writer joins them.
- **Scale down:** the ASG terminates instances; each leaves cleanly via its shutdown hook; the watcher purges them. The read target group's `deregistration_delay` is set to **30 s** (down from the AWS default of 300 s) — read replicas are stateless with sub-second requests, so there's nothing to drain for 5 minutes. A full **16→1 takes ~3 min** (measured ~183 s).
- The writer and surviving readers stay available throughout.

> **Large bulk scale-downs can be disruptive.** Removing many nodes at once (e.g. `16→1`) *occasionally* triggers a fencing storm that briefly drops the cluster below target before it self-heals (intermittent — see [Troubleshooting #10](11-troubleshooting.md)). For big reductions, prefer stepping down a few nodes at a time and letting it stabilise between steps; small removals are reliable.

"Ready" means: ASG `InService == N`, the writer's `/cluster/nodes` reports `online == N`, and every node's `/health` is `ok`. (This is exactly the readiness definition the test harness uses — chapter 9.)

### Promote (failover)

Promotes a reader to writer; the old writer is **demoted in place** (not terminated).

```bash
# TUI:   promote <node_id>
# Shell:
./scripts/promote_reader.sh <READER_PUBLIC_IP>
```

Sequence (~1.5 min):
1. `POST /admin/demote` to the current writer → it restarts read-only; wait until it confirms `readonly`.
2. Retag the old writer as reader and drop its scale-in protection.
3. `POST /admin/promote` to the target → it updates SSM, removes the RocksDB `LOCK`, restarts read-write.
4. `POST /admin/start-watcher` on the new writer; set its scale-in protection; update SSM/tags.

The TUI rolls back automatically (re-promotes the old writer) if the promote fails.

### Kill a node (and auto-recovery)

```bash
# TUI:   kill <node_id>
# Shell:
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
```

The ASG launches a replacement, which boots and rejoins. If you kill the **writer**, write capability pauses until you promote a reader (the TUI warns you). Recovery to full size: **~5–7 min** (measured 7m20s on the current build) — dominated by the ASG launching and **booting a fresh replacement** instance, then rejoining (the same EC2-boot cost as adding any new reader).

### Read / write / scan / delete

Port 8080 is **not** publicly reachable (the security group allows it only from the ALB), so direct operations run **on the node via SSM** against `http://localhost:8080`. Load-balanced reads can also go through the ALB on port 80. The TUI and test harness do this for you.

```bash
# On a node via SSM Run Command (writes/deletes → WRITER only; reads/scans → any node):
aws ssm send-command --instance-ids <WRITER_INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -s -X POST http://localhost:8080/put -H \"Content-Type: application/json\" -d {\"key\":\"hello\",\"value\":\"world\"}"]'

# Load-balanced reads through the ALB (port 80):
curl -s "http://<ALB_DNS>/get?key=hello"
curl -s "http://<ALB_DNS>/scan"
```

After a write/delete the writer auto-flushes, so readers reflect the change within ~10 ms.

### Reset the database

`/admin/*` endpoints require the bearer token and are reachable only on-box (the ALB blocks `/admin/*`). Run via SSM on the writer; the token is read from the node's own `service.env`:

```bash
# TUI:   resetdb       (writer only — wipes ALL data)
aws ssm send-command --instance-ids <WRITER_INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[". /etc/rocksdb/service.env; curl -s -X POST http://localhost:8080/admin/resetdb -H \"Authorization: Bearer $ADMIN_TOKEN\""]'
```

## Recovery procedures

### Cluster is in a bad state (fencing storms, GFS2 won't mount)

Rebuild the cluster from scratch (data on the volume is preserved). `setup_cluster.sh` now runs over SSM — open a Session Manager shell on the writer and invoke it locally:

```bash
aws ssm start-session --target <WRITER_INSTANCE_ID>
sudo /usr/local/bin/setup_cluster.sh    # force-stops everything, recreates cluster, remounts GFS2
```

### Writer is down

Promote a reader (`promote <id>` / `promote_reader.sh`). If the old writer died ungracefully and left a stale `LOCK`, the promote path removes it automatically. If you ever need to do it by hand on the new writer:

```bash
sudo rm /data/rocksdb/db/LOCK && sudo systemctl restart rocksdb.service
```

### A reader won't join

Check its boot log and cluster status (over SSM):

```bash
aws ssm start-session --target <NODE_INSTANCE_ID>
sudo cat /var/log/rocksdb-userdata.log
sudo pcs status
```

Common causes: the EBS attach lost a race (it retries and usually wins next cycle), or the writer hadn't finished writing auth keys to SSM yet.

### Recycle the whole fleet onto a new AMI

After rebuilding the AMI, scale down to 1 and terminate instances (or scale to 1 then recycle) — the ASG relaunches them from the new launch template, and the writer-election logic brings a fresh writer up on the new image with data intact.

### Reset accumulated corosync drift (heavily scale-cycled writer)

Many scale up/down cycles leave ghost entries in the writer's corosync **runtime nodelist** (e.g. ~15 per `1→16→1`). These ghosts are now prevented from causing harm by **Last Man Standing + the watcher pinning `expected_votes` to the live count** (without those, ghosts inflate `expected_votes`, the live set loses quorum, and DLM freezes all I/O — see [Troubleshooting #5](11-troubleshooting.md)). The ghosts themselves still accumulate; to clear them back to a clean `runtime = 1`, **recycle the writer**:

```bash
ASG=$(aws cloudformation describe-stacks --stack-name RocksDbStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ASGName`].OutputValue' --output text)
WID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=RocksDB-Writer \
  Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws autoscaling set-instance-protection --instance-ids "$WID" \
  --auto-scaling-group-name "$ASG" --no-protected-from-scale-in
aws ec2 terminate-instances --instance-ids "$WID"
```

The ASG relaunches a fresh writer that remounts the data with clean corosync state (~2 min, data preserved).

## Teardown

```bash
./destroy.sh         # = uv run cdk destroy --all --require-approval never --force
```

`destroy.sh` now also deletes the **runtime-created** SSM parameters that instances write at boot (so `cdk destroy` alone wouldn't remove them): `/rocksdb-cluster/{corosync-authkey, pacemaker-authkey, hacluster-password, admin-token, writer-instance-id}`. The CDK-managed `volume-id` is removed with the stack. This prevents leftover secrets from lingering after teardown.

If you ever need to clean them by hand:

```bash
for P in corosync-authkey pacemaker-authkey hacluster-password admin-token writer-instance-id; do
  aws ssm delete-parameter --name "/rocksdb-cluster/$P" --region us-east-1 2>/dev/null
done
```

If VPC deletion fails because of a leftover `rocksdb-loader-sg` (from stress tests), delete that security group and retry.

## How long things take

Measured on `m5d.2xlarge` in `us-east-1` (2026-06-16 clean full validation run). "Duration" is time until all target nodes are operational — **not** downtime (the writer and existing readers stay up).

| Operation | Duration | Notes |
|---|---|---|
| Scale 1 → 8 | ~7 min | Readers added one at a time |
| Scale 8 → 3 | ~6.5 min | Scale-down + ghost purge |
| Scale 3 → 16 | ~17 min | 13 readers added sequentially |
| Scale 16 → 5 | ~6.5 min | Scale-down + ghost purge |
| Recycle whole fleet onto a new AMI (→1) | ~6 min | Terminate all; fresh writer boots + self-configures |
| Kill 1 reader → recover | ~4.5 min | ASG replacement boots and rejoins |
| Kill 2 readers back-to-back → recover | ~6.5 min | Both replacements rejoin; no wedge |
| Promote a reader to writer | ~1.5 min | Demote old + promote new + verify |
| Data op (write / read / scan / delete) | <10 s | Single REST call |
| Write visible on readers | ~10 ms | Auto-flush + `TryCatchUpWithPrimary` |

Rule of thumb: adding readers is paced at roughly **~40 s/node**, so a full **1→16 ≈ 14 min end-to-end** (the cluster watcher joins nodes one at a time — deliberately, since batch joins caused split-brain; see [Troubleshooting](11-troubleshooting.md)); a full **16→1 ≈ 3 min**. The writer and all surviving readers remain fully available throughout.

> **Measured end-to-end (token=30000, 16× `m5d.2xlarge`, fresh writer).** From issuing the scale command to **all nodes serving** (ALB-healthy + Corosync-online), scale-up is reliable with **zero token-loss events**: full **1→16 ≈ 13–14 min** across three runs (755 s, 779 s, 823 s) — a steady ~40 s/node after the first ~3 min of ASG boot — and **16→1 ≈ 3 min** (173–183 s). **Promote/failover ≈ 1–1.5 min** (measured 1m06s; prior run 1m36s). **Kill→recover ≈ 5–7 min** (measured 7m20s) — recovery is dominated by the ASG booting a fresh replacement and rejoining it. The older per-operation table above predates the token fix and is kept as a reference for partial scales.

---
Next: [The TUI →](08-tui.md)
