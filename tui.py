#!/usr/bin/env python3
"""
RocksDB Cluster Manager — Textual TUI
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess  # nosec B404 - used only for local clipboard integration (pbcopy/xclip)
import tempfile
import time
from datetime import datetime, timezone, timedelta
from typing import Any

from collections import deque

import boto3
import httpx
from rich.text import Text as RichText
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, Vertical
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import DataTable, Footer, Input, Label, RichLog, Static

REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
STACK_NAME = "RocksDbStack"
REFRESH_INTERVAL = 10  # seconds between AWS data refresh (API calls are slow)
CLUSTER_NAME = "rocksdb-cluster"

# ── AWS helpers ───────────────────────────────────────────────────────────────

def _cfn_output(key: str) -> str:
    cf = boto3.client("cloudformation", region_name=REGION)
    try:
        r = cf.describe_stacks(StackName=STACK_NAME)
        for o in r["Stacks"][0].get("Outputs", []):
            if o["OutputKey"] == key:
                return o["OutputValue"]
    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
        pass
    return ""


def _get_asg_name() -> str:
    return _cfn_output("ASGName")


def _get_alb_dns() -> str:
    return _cfn_output("ReadAlbDns")


def _get_volume_id() -> str:
    return _cfn_output("DataVolumeId")


def _get_alb_arn() -> str:
    elb = boto3.client("elbv2", region_name=REGION)
    try:
        r = elb.describe_load_balancers()
        for lb in r["LoadBalancers"]:
            if "ReadA" in lb.get("LoadBalancerName", "") or "rocksdb" in lb.get("LoadBalancerName", "").lower():
                return lb["LoadBalancerArn"]
    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
        pass
    return ""


def _alb_suffix(arn: str) -> str:
    # Extract app/name/id portion from ARN
    m = re.search(r"loadbalancer/(app/.+)$", arn)
    return m.group(1) if m else ""


def _ago_iso(secs: int) -> str:
    t = datetime.now(timezone.utc) - timedelta(seconds=secs)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _fmt_bytes(b: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PiB"


# ── SSM-backed REST shim ──────────────────────────────────────────────────────
# The REST API is no longer reachable from the internet (security group allows
# :8080 only from the ALB, and /admin/* is blocked at the ALB). All per-node REST
# calls are therefore executed ON the target node via SSM Run Command, hitting
# http://localhost:8080. The admin bearer token is read from the node's own
# /etc/rocksdb/service.env, so the secret never leaves the instance.
#
# `httpx` is shadowed below with a minimal-compatible shim so existing call sites
# (httpx.get / httpx.post / httpx.Client().post, with .json()/.text/.content/
# .status_code on the response) keep working unchanged.

_CODE_MARK = "<<<HTTPCODE>>>"
_IID_CACHE: dict[str, str] = {}


class _Resp:
    def __init__(self, text: str = "", status: int = 0):
        self.text = text or ""
        self.status_code = status

    def json(self) -> dict:
        try:
            return json.loads(self.text) if self.text else {}
        except Exception:
            return {}

    @property
    def content(self) -> bytes:
        return self.text.encode("latin-1", "ignore")


def _resolve_iid(target: str) -> str:
    """Resolve a public IP / private IP / instance-id to an instance id (cached)."""
    if not target:
        return ""
    if target.startswith("i-"):
        return target
    if target in _IID_CACHE:
        return _IID_CACHE[target]
    ec2 = boto3.client("ec2", region_name=REGION)
    iid = ""
    for filt in ("ip-address", "private-ip-address"):
        try:
            r = ec2.describe_instances(Filters=[
                {"Name": "instance-state-name", "Values": ["running"]},
                {"Name": filt, "Values": [target]},
            ])
            for res in r["Reservations"]:
                for inst in res["Instances"]:
                    iid = inst["InstanceId"]
                    break
                if iid:
                    break
        except Exception:  # nosec B110 - best-effort resolution; non-fatal
            pass
        if iid:
            break
    if iid:
        _IID_CACHE[target] = iid
    return iid


def _ssm_run(iid: str, cmd: str, wait: int = 60) -> str:
    """Run a shell command on an instance via SSM; return stdout (base64-wrapped
    to avoid quoting issues)."""
    import base64
    ssm = boto3.client("ssm", region_name=REGION)
    b64 = base64.b64encode(cmd.encode()).decode()
    try:
        send = ssm.send_command(
            InstanceIds=[iid],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [f"echo {b64} | base64 -d | bash"]},
        )
        cid = send["Command"]["CommandId"]
    except Exception:
        return ""
    end = time.time() + wait
    while time.time() < end:
        time.sleep(2)  # nosemgrep: arbitrary-sleep - intentional SSM poll interval
        try:
            inv = ssm.get_command_invocation(CommandId=cid, InstanceId=iid)
        except Exception:  # nosec B112 - transient SSM read; retry on next poll
            continue
        st = inv.get("Status")
        if st == "Success":
            return inv.get("StandardOutputContent", "")
        if st in ("Failed", "Cancelled", "TimedOut"):
            return ""
    return ""


def _node_call(url: str, method: str, json_body=None, params=None, timeout: int = 30) -> _Resp:
    m = re.match(r"http://([^:/]+):8080(/.*)?$", url)
    if not m:
        return _Resp("", 0)
    host, path = m.group(1), (m.group(2) or "/")
    if params:
        from urllib.parse import urlencode
        sep = "&" if "?" in path else "?"
        path = f"{path}{sep}{urlencode(params)}"
    iid = _resolve_iid(host)
    if not iid:
        return _Resp("", 0)
    body = ""
    if json_body is not None:
        body = json.dumps(json_body)
    cmd = "TOK=$(grep -oP 'ADMIN_TOKEN=\\K.*' /etc/rocksdb/service.env 2>/dev/null); "
    cmd += (f"curl -s -w '{_CODE_MARK}%{{http_code}}' --max-time {timeout} "
            f"-X {method} -H \"Authorization: Bearer $TOK\" -H 'Content-Type: application/json'")
    if body:
        safe = body.replace("'", "'\\''")
        cmd += f" --data '{safe}'"
    cmd += f" http://localhost:8080{path}"
    out = _ssm_run(iid, cmd, wait=int(timeout) + 30)
    status, text = 0, out
    if _CODE_MARK in out:
        text, _, code = out.rpartition(_CODE_MARK)
        try:
            status = int(code.strip())
        except Exception:
            status = 0
    return _Resp(text, status)


class _NodeHTTP:
    """Minimal httpx-compatible facade that routes node :8080 calls through SSM."""

    def get(self, url, params=None, timeout=30, headers=None):
        return _node_call(url, "GET", params=params, timeout=int(timeout or 30))

    def post(self, url, json=None, timeout=30, headers=None):
        return _node_call(url, "POST", json_body=json, timeout=int(timeout or 30))

    def Client(self, *args, **kwargs):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


_real_httpx = httpx  # real HTTP client, kept for direct ALB (data-plane) calls
httpx = _NodeHTTP()  # noqa: F811 — route all node REST through SSM (no public :8080)


# ── Data fetchers (run in threads via asyncio.to_thread) ──────────────────────

def fetch_nodes(asg_name: str) -> list[dict]:
    """Return enriched node list from EC2 + ASG."""
    if not asg_name:
        return []
    ec2 = boto3.client("ec2", region_name=REGION)
    asg = boto3.client("autoscaling", region_name=REGION)
    try:
        asg_resp = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
        instances = asg_resp["AutoScalingGroups"][0]["Instances"]
    except Exception:
        return []

    if not instances:
        return []

    ids = [i["InstanceId"] for i in instances]
    asg_map = {i["InstanceId"]: i for i in instances}

    try:
        ec2_resp = ec2.describe_instances(InstanceIds=ids)
    except Exception:
        return []

    nodes = []
    for res in ec2_resp["Reservations"]:
        for inst in res["Instances"]:
            iid = inst["InstanceId"]
            asg_inst = asg_map.get(iid, {})
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            role = tags.get("rocksdb-role", "reader")
            name = tags.get("Name", iid)
            lifecycle = asg_inst.get("LifecycleState", "Unknown")
            health = asg_inst.get("HealthStatus", "?")
            priv_ip = inst.get("PrivateIpAddress", "")
            pub_ip = inst.get("PublicIpAddress", "")
            state = inst.get("State", {}).get("Name", "unknown")
            nodes.append({
                "id": iid,
                "name": name,
                "role": role,
                "state": state,
                "health": health,
                "lifecycle": lifecycle,
                "priv_ip": priv_ip,
                "pub_ip": pub_ip,
            })
    # writer first
    nodes.sort(key=lambda n: (0 if n["role"] == "writer" else 1, n["priv_ip"]))
    return nodes


def fetch_node_ids(any_ip: str) -> dict[str, int]:
    """Map private IP → corosync node ID. Uses IP→ID map from /cluster/nodeids."""
    if not any_ip:
        return {}
    try:
        r = httpx.get(f"http://{any_ip}:8080/cluster/nodeids", timeout=5)
        return {ip: int(nid) for ip, nid in r.json().get("map", {}).items()}
    except Exception:
        return {}

def fetch_health(ip: str) -> dict:
    try:
        r = httpx.get(f"http://{ip}:8080/health", timeout=4)
        return r.json()
    except Exception:
        return {}


def fetch_volume(volume_id: str) -> dict:
    if not volume_id:
        return {}
    ec2 = boto3.client("ec2", region_name=REGION)
    try:
        r = ec2.describe_volumes(VolumeIds=[volume_id])
        v = r["Volumes"][0]
        return {
            "vol_id": volume_id,
            "size_gib": v.get("Size", 0),
            "iops": v.get("Iops", 0),
            "throughput": v.get("Throughput", 0),
            "state": v.get("State", "unknown"),
            "type": v.get("VolumeType", ""),
        }
    except Exception:
        return {}


def fetch_db_size(writer_ip: str) -> int:
    if not writer_ip:
        return 0
    try:
        r = httpx.get(f"http://{writer_ip}:8080/admin/dbsize", timeout=5)
        return r.json().get("bytes", 0)
    except Exception:
        return 0


def fetch_metrics(alb_suffix: str, volume_id: str) -> dict:
    cw = boto3.client("cloudwatch", region_name=REGION)
    result = {"alb_rps": None, "alb_p99_ms": None, "ebs_iops": None, "ebs_mbs": None}

    start = _ago_iso(120)
    end = _now_iso()

    def _stat(ns, metric, dim_name, dim_val, stat):
        try:
            r = cw.get_metric_statistics(
                Namespace=ns, MetricName=metric,
                Dimensions=[{"Name": dim_name, "Value": dim_val}],
                StartTime=start, EndTime=end,
                Period=60, Statistics=[stat],
            )
            pts = sorted(r["Datapoints"], key=lambda x: x["Timestamp"])
            return pts[-1][stat] if pts else None
        except Exception:
            return None

    # ALB RPS
    if alb_suffix:
        raw = _stat("AWS/ApplicationELB", "RequestCount", "LoadBalancer", alb_suffix, "Sum")
        result["alb_rps"] = int(raw / 60) if raw is not None else None

        # ALB p99 via get_metric_data
        try:
            r = cw.get_metric_data(
                MetricDataQueries=[{
                    "Id": "p99",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/ApplicationELB",
                            "MetricName": "TargetResponseTime",
                            "Dimensions": [{"Name": "LoadBalancer", "Value": alb_suffix}],
                        },
                        "Period": 60,
                        "Stat": "p99",
                    },
                }],
                StartTime=start, EndTime=end,
            )
            vals = r["MetricDataResults"][0].get("Values", [])
            result["alb_p99_ms"] = round(vals[-1] * 1000, 1) if vals else None
        except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
            pass

    # EBS IOPS + MB/s
    if volume_id:
        read_ops = _stat("AWS/EBS", "VolumeReadOps", "VolumeId", volume_id, "Sum")
        write_ops = _stat("AWS/EBS", "VolumeWriteOps", "VolumeId", volume_id, "Sum")
        read_bytes = _stat("AWS/EBS", "VolumeReadBytes", "VolumeId", volume_id, "Sum")
        if read_ops is not None and write_ops is not None:
            result["ebs_iops"] = int((read_ops + write_ops) / 60)
        if read_bytes is not None:
            result["ebs_mbs"] = round(read_bytes / 60 / 1024 / 1024, 1)

    return result


# ── Widgets ───────────────────────────────────────────────────────────────────



# (key in metrics dict, display label, unit suffix, storage transform)
GRAPH_METRICS = [
    ("alb_rps",    "alb rps",    "",      lambda v: v),
    ("alb_p99_ms", "alb p99",    " ms",   lambda v: v),
    ("ebs_iops",   "ebs iops",   "",      lambda v: v),
    ("ebs_mbs",    "ebs mb/s",   " MB/s", lambda v: v),
    ("db_mib",     "db size",    " MiB",  lambda v: v),
]

_BLOCKS = " ▁▂▃▄▅▆▇█"


class MetricGraph(Widget):
    """Live ASCII time-series graph. Press [m] to cycle metrics."""

    idx: reactive[int] = reactive(0)

    DEFAULT_CSS = """
    MetricGraph {
        width: 1fr;
        height: 1fr;
        background: #0d1117;
        border-left: tall #30363d;
        padding: 0;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._data: dict[str, deque] = {k: deque(maxlen=120) for k, *_ in GRAPH_METRICS}

    def push(self, key: str, value: float | None) -> None:
        if value is not None and key in self._data:
            self._data[key].append(float(value))
            if GRAPH_METRICS[self.idx][0] == key:
                self.refresh()

    def cycle(self, direction: int = 1) -> None:
        self.idx = (self.idx + direction) % len(GRAPH_METRICS)

    def watch_idx(self, _: int) -> None:
        self.refresh()

    def render(self) -> RichText:  # noqa: C901
        key, label, unit, _ = GRAPH_METRICS[self.idx]
        data = list(self._data[key])

        tw, th = self.size.width, self.size.height
        if tw == 0 or th == 0:
            return RichText()

        Y_W   = 10   # y-axis label column width (chars)
        HDR_H = 1    # header row
        XAX_H = 2    # x-axis line + labels row

        plot_w = max(tw - Y_W - 1, 4)
        plot_h = max(th - HDR_H - XAX_H, 4)

        out = RichText()

        # ── header ─────────────────────────────────────────────────
        cur_str = f"{data[-1]:,.1f}{unit}" if data else "—"
        out.append(f" {label}", style="bold #f0883e")
        out.append(f"  {cur_str}", style="bold #e6edf3")
        out.append(f"  [{self.idx+1}/{len(GRAPH_METRICS)}]  {len(data)}pts", style="#6e7681")
        out.append(f"  [n]◀ [m]▶\n", style="dim #6e7681")

        # ── no data ─────────────────────────────────────────────────
        if len(data) < 2:
            for _ in range(plot_h):
                out.append(" " * (Y_W - 1) + "│", style="#30363d")
                out.append("·" * plot_w + "\n", style="#1c2128")
            out.append(" " * (Y_W - 1) + "└" + "─" * plot_w + "\n", style="#30363d")
            out.append(" " * Y_W + f"{'waiting for data…':^{plot_w}}\n", style="#6e7681")
            return out

        # ── compute ─────────────────────────────────────────────────
        pts = data[-plot_w:]
        n   = len(pts)
        max_v = max(pts)
        min_v = min(pts)
        rng   = max_v - min_v or 1

        def _fmt_val(v: float) -> str:
            if abs(v) >= 1_000_000:
                return f"{v / 1_000_000:.1f}M"
            if abs(v) >= 1_000:
                return f"{v / 1_000:.1f}k"
            return f"{v:.1f}"

        def to_row(v: float) -> int:
            return max(0, min(plot_h - 1,
                              int(round((1.0 - (v - min_v) / rng) * (plot_h - 1)))))

        y_pos = [to_row(v) for v in pts]

        # ── build character grid ─────────────────────────────────────
        grid: list[list[str]] = [[" "] * n for _ in range(plot_h)]

        for i in range(n):
            r = y_pos[i]
            grid[r][i] = "●"
            if i > 0:
                r_prev = y_pos[i - 1]
                lo, hi = min(r, r_prev), max(r, r_prev)
                for fill_r in range(lo + 1, hi):
                    grid[fill_r][i] = "│"

        # ── y-axis tick rows ─────────────────────────────────────────
        n_ticks  = min(5, plot_h)
        tick_rows = {
            int(round(i * (plot_h - 1) / max(n_ticks - 1, 1))): i
            for i in range(n_ticks)
        }

        # ── render rows ──────────────────────────────────────────────
        for r in range(plot_h):
            if r in tick_rows:
                v_at = max_v - (max_v - min_v) * r / max(plot_h - 1, 1)
                lbl = _fmt_val(v_at)
                out.append(f"{lbl:>{Y_W - 2}} ┤", style="#6e7681")
            else:
                out.append(" " * (Y_W - 1) + "│", style="#30363d")

            for c in range(n):
                ch = grid[r][c]
                if ch == "●":
                    out.append("●", style="bold #f0883e")
                elif ch == "│":
                    out.append("│", style="#f0883e")
                else:
                    out.append(" ")
            out.append("\n")

        # ── x-axis line ──────────────────────────────────────────────
        out.append(" " * (Y_W - 1) + "└" + "─" * n + "\n", style="#30363d")

        # ── x-axis labels: oldest left, "now" right ──────────────────
        total_secs = len(data) * REFRESH_INTERVAL
        if total_secs >= 60:
            left_lbl = f"{total_secs // 60}m ago"
        else:
            left_lbl = f"{total_secs}s ago"
        right_lbl = "now"
        mid_secs  = total_secs // 2
        mid_lbl   = f"{mid_secs // 60}m" if mid_secs >= 60 else f"{mid_secs}s"

        inner = n
        gap   = inner - len(left_lbl) - len(right_lbl)
        if gap >= len(mid_lbl) + 2:
            mid_pad_l = inner // 2 - len(left_lbl) - len(mid_lbl) // 2
            mid_pad_r = inner - len(left_lbl) - mid_pad_l - len(mid_lbl) - len(right_lbl)
            x_line = (left_lbl + " " * max(0, mid_pad_l) +
                      mid_lbl + " " * max(0, mid_pad_r) + right_lbl)
        elif gap >= 0:
            x_line = left_lbl + " " * gap + right_lbl
        else:
            x_line = right_lbl.rjust(inner)

        out.append(" " * Y_W + x_line, style="#6e7681")
        return out


class SectionTitle(Static):
    DEFAULT_CSS = """
    SectionTitle {
        color: #8b949e;
        text-style: bold;
        padding: 0 2;
        height: 1;
        background: #161b22;
        width: 1fr;
        border-left: tall #f0883e;
    }
    """


class MetricBox(Static):
    DEFAULT_CSS = """
    MetricBox {
        border: tall #30363d;
        padding: 0 1;
        height: 7;
        min-width: 18;
        background: #161b22;
    }
    MetricBox .metric-label {
        color: #8b949e;
        text-style: none;
        height: 1;
    }
    MetricBox .metric-value {
        color: #f0883e;
        text-style: bold;
        height: 4;
        content-align: center middle;
    }
    """

    def __init__(self, label: str, value: str = "—", **kwargs):
        super().__init__(**kwargs)
        self._label = label
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label(self._label, classes="metric-label")
        yield Label(self._value, classes="metric-value")

    def update_value(self, value: str) -> None:
        self.query_one(".metric-value", Label).update(value)


# ── Main App ──────────────────────────────────────────────────────────────────

APP_CSS = """
Screen {
    background: #0d1117;
}

/* ── Header ── */
#header-bar {
    height: 3;
    background: #161b22;
    padding: 0 2;
    align: center middle;
    border-bottom: tall #30363d;
}

#header-title {
    color: #e6edf3;
    text-style: bold;
    width: auto;
    height: 3;
    content-align: center middle;
    padding: 0 2 0 0;
}

#header-region {
    color: #f0883e;
    width: auto;
    height: 3;
    content-align: center middle;
    padding: 0 2;
    border-left: tall #30363d;
    border-right: tall #30363d;
}

#header-meta {
    color: #8b949e;
    width: auto;
    height: 3;
    content-align: center middle;
    padding: 0 0 0 2;
}

/* ── Main layout ── */
#main-layout {
    height: 1fr;
}

/* ── Section titles ── */
SectionTitle {
    color: #8b949e;
    text-style: bold;
    padding: 0 2;
    height: 1;
    background: #161b22;
    width: 1fr;
    border-left: tall #f0883e;
}

/* ── Nodes section ── */
#nodes-section {
    height: 19;
    padding: 0;
}

/* ── Metric graph ── */
#metric-graph {
    width: 1fr;
    height: 1fr;
    background: #0d1117;
    border-left: tall #30363d;
}

/* ── DataTable ── */
DataTable {
    width: 1fr;
    height: 1fr;
    background: #0d1117;
}

DataTable > .datatable--header {
    background: #161b22;
    color: #8b949e;
    text-style: bold;
}

DataTable > .datatable--cursor {
    background: #1c2128;
    color: #e6edf3;
}

DataTable > .datatable--even-row {
    background: #0d1117;
}

DataTable > .datatable--odd-row {
    background: #0f141b;
}

/* ── Bottom strip ── */
#bottom-strip {
    height: 1fr;
    border-top: tall #30363d;
}

/* ── Volume panel ── */
#vol-panel {
    width: 46;
    border-right: tall #30363d;
    background: #0d1117;
}

#volume-section {
    height: 1fr;
    padding: 1 2;
}

/* ── Right panel ── */
#right-panel {
    width: 1fr;
    background: #0d1117;
}

/* ── Metrics grid ── */
#metrics-grid {
    height: 9;
    layout: horizontal;
    align: left middle;
    padding: 0 1;
    background: #0d1117;
}

MetricBox {
    border: tall #30363d;
    padding: 0 1;
    height: 7;
    width: 1fr;
    margin: 1 1 0 0;
    background: #161b22;
}

.metric-label {
    color: #8b949e;
    height: 1;
    text-style: none;
}

.metric-value {
    color: #f0883e;
    text-style: bold;
    height: 4;
    content-align: center middle;
    width: 1fr;
}

/* ── Command section ── */
#cmd-section {
    height: 1fr;
    padding: 0;
}

#cmd-log {
    height: 1fr;
    border: none;
    padding: 0 2;
    scrollbar-size: 1 1;
    background: #0d1117;
}

#cmd-input-row {
    height: 3;
    padding: 0 2;
    align: left middle;
    border-top: tall #30363d;
    background: #161b22;
}

#cmd-prompt {
    color: #3fb950;
    width: auto;
    padding: 0 1 0 0;
    text-style: bold;
}

#cmd-input {
    width: 1fr;
    border: none;
    background: #161b22;
    color: #e6edf3;
}

#cmd-input:focus {
    border: none;
    background: #161b22;
}

/* ── Status bar ── */
#status-bar {
    height: 1;
    background: #161b22;
    color: #8b949e;
    padding: 0 2;
    dock: bottom;
    border-top: tall #30363d;
}

/* ── Footer ── */
Footer {
    background: #161b22;
    color: #8b949e;
}

Footer > .footer--key {
    background: #30363d;
    color: #f0883e;
}
"""


class RocksDBTUI(App):
    """RocksDB Cluster Manager TUI."""

    CSS = APP_CSS
    TITLE = "RocksDB Cluster Manager"
    ENABLE_COMMAND_PALETTE = False
    BINDINGS = [
        Binding("ctrl+r", "refresh", "Refresh", show=True),
        Binding("ctrl+q", "quit", "Quit", show=True),
        Binding("f1", "focus_input", "Command", show=True),
        Binding("m", "cycle_metric_fwd", "Next metric", show=True),
        Binding("n", "cycle_metric_bwd", "Prev metric", show=True),
    ]

    # State — plain instance vars (prefixed st_ to avoid Textual internal name conflicts)
    st_nodes: list[dict] = []
    st_volume: dict = {}
    st_metrics: dict = {}
    st_db_size: int = 0
    st_alb_dns: str = ""
    st_asg_name: str = ""
    st_volume_id: str = ""
    st_alb_suffix: str = ""
    st_stress_active: bool = False
    _log_buffer: list[str] = []
    st_refreshing: bool = False  # guard against concurrent refreshes
    _last_refresh_ts: str = "never"

    def compose(self) -> ComposeResult:
        # Header
        with Horizontal(id="header-bar"):
            yield Static("rocksdb  cluster manager", id="header-title")
            yield Static(REGION, id="header-region")
            yield Static("", id="header-meta")

        # Main layout — nodes full width on top, bottom strip below
        with Vertical(id="main-layout"):
            # Top: full-width nodes table
            yield SectionTitle("nodes", id="title-nodes")
            with Horizontal(id="nodes-section"):
                yield DataTable(id="nodes-table", cursor_type="row", zebra_stripes=True)
                yield MetricGraph(id="metric-graph")

            # Bottom strip: volume | metrics+command
            with Horizontal(id="bottom-strip"):
                # Volume panel (fixed width)
                with Vertical(id="vol-panel"):
                    yield SectionTitle("ebs volume", id="title-volume")
                    with Vertical(id="volume-section"):
                        yield Static("", id="vol-display")

                # Right side: metrics on top, command below
                with Vertical(id="right-panel"):
                    yield SectionTitle("metrics  ·  60s window", id="title-metrics")
                    with Horizontal(id="metrics-grid"):
                        yield MetricBox("alb rps", "—", id="m-alb-rps")
                        yield MetricBox("alb p99 ms", "—", id="m-alb-p99")
                        yield MetricBox("ebs iops", "—", id="m-ebs-iops")
                        yield MetricBox("ebs mb/s", "—", id="m-ebs-mbs")
                        yield MetricBox("db size", "—", id="m-db-size")
                    yield SectionTitle("output", id="title-cmd")
                    with Container(id="cmd-section"):
                        yield RichLog(id="cmd-log", highlight=True, markup=True, wrap=True)
                        with Horizontal(id="cmd-input-row"):
                            yield Static("❯", id="cmd-prompt")
                            yield Input(placeholder="scale 1-16 | promote <id> | kill <id> | write <key> <val> | read [id] <key> | scan [id] | delete <key> | resetdb | stress-test | help", id="cmd-input")

        yield Static("", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        # Setup nodes table columns
        tbl = self.query_one("#nodes-table", DataTable)
        tbl.add_columns("Role", "Instance ID", "Private IP", "Public IP", "Svc Health", "ASG Lifecycle", "Node ID")
        # Initial load
        self.action_refresh()
        # AWS data refresh every 10s
        self.set_interval(REFRESH_INTERVAL, self.action_refresh)
        # Status bar clock tick every 1s — no AWS calls, keeps UI feeling live
        self.set_interval(1, self._tick_status)

    def _tick_status(self) -> None:
        if not self.st_refreshing:
            ts = datetime.now().strftime("%H:%M:%S")
            self.query_one("#status-bar", Static).update(
                f"[dim]{ts}[/dim]  last refresh: {self._last_refresh_ts}  "
                f"[dim]·  auto every {REFRESH_INTERVAL}s[/dim]"
            )

    def action_focus_input(self) -> None:
        self.query_one("#cmd-input", Input).focus()

    def action_cycle_metric_fwd(self) -> None:
        self.query_one("#metric-graph", MetricGraph).cycle(1)

    def action_cycle_metric_bwd(self) -> None:
        self.query_one("#metric-graph", MetricGraph).cycle(-1)

    def action_refresh(self) -> None:
        self._do_refresh()

    @work(thread=True)
    def _do_refresh(self) -> None:
        if self.st_refreshing:
            return
        self.st_refreshing = True
        try:
            self._do_refresh_inner()
        finally:
            self.st_refreshing = False

    def _do_refresh_inner(self) -> None:
        # Fetch stack outputs once — keyed on asg_name being populated
        if not self.st_asg_name:
            self.call_from_thread(self._set_status, "fetching stack outputs…", "dim")
            asg     = _get_asg_name()
            alb_dns = _get_alb_dns()
            vol_id  = _get_volume_id()
            suffix  = _alb_suffix(_get_alb_arn())
            self.call_from_thread(self._apply_stack_outputs, asg, alb_dns, vol_id, suffix)
        else:
            asg    = self.st_asg_name
            vol_id = self.st_volume_id
            suffix = self.st_alb_suffix

        self.call_from_thread(self._set_status, "refreshing…", "dim")

        # Fetch nodes
        nodes = fetch_nodes(asg)
        writer_ip = next((n["pub_ip"] for n in nodes if n["role"] == "writer"), "")

        # Fetch corosync node IDs — try all nodes until one responds
        node_id_map = {}
        for n in nodes:
            if n.get("pub_ip"):
                node_id_map = fetch_node_ids(n["pub_ip"])
                if node_id_map:
                    break

        # Enrich nodes with health + node ID in parallel
        import concurrent.futures
        def _enrich(n):
            h = fetch_health(n["pub_ip"]) if n["pub_ip"] else {}
            n["svc_status"] = h.get("status", "?")
            n["svc_mode"] = h.get("mode", "?")
            n["node_id"] = node_id_map.get(n["priv_ip"], "—")
            return n

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
            nodes = list(ex.map(_enrich, nodes))

        # Fetch volume, metrics, db size in parallel
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
            f_vol  = ex.submit(fetch_volume, vol_id)
            f_met  = ex.submit(fetch_metrics, suffix, vol_id)
            f_db   = ex.submit(fetch_db_size, writer_ip)
            vol   = f_vol.result()
            met   = f_met.result()
            db_sz = f_db.result()

        ts = datetime.now().strftime("%H:%M:%S")
        self.call_from_thread(self._apply_refresh, nodes, vol, met, db_sz, ts)

    def _apply_stack_outputs(self, asg: str, alb_dns: str, vol_id: str, suffix: str) -> None:
        self.st_asg_name = asg
        self.st_alb_dns = alb_dns
        self.st_volume_id = vol_id
        self.st_alb_suffix = suffix
        self.query_one("#header-meta", Static).update(
            f"[#8b949e]alb[/#8b949e] {alb_dns}  [#8b949e]asg[/#8b949e] {asg}"
        )

    def _apply_refresh(self, nodes, vol, met, db_sz, ts) -> None:
        self.st_nodes = nodes
        self.st_volume = vol
        self.st_metrics = met
        self.st_db_size = db_sz
        self._last_refresh_ts = ts
        self._render_nodes(nodes)
        self._render_volume(vol)
        self._render_metrics(met, db_sz)
        self._set_status(f"last refresh: {ts}  [dim]·  auto every {REFRESH_INTERVAL}s[/dim]")

    def _render_nodes(self, nodes: list[dict]) -> None:
        tbl = self.query_one("#nodes-table", DataTable)
        tbl.clear()
        total = len(nodes)
        writers = sum(1 for n in nodes if n["role"] == "writer")
        readers = total - writers
        w_label = f"writer{'s' if writers != 1 else ''}"
        r_label = f"reader{'s' if readers != 1 else ''}"
        self.query_one("#title-nodes", SectionTitle).update(
            f"nodes   {writers} {w_label}  /  {readers} {r_label}  /  {total} total"
        )
        for n in nodes:
            role = n["role"]
            role_str = "[bold #3fb950]writer[/bold #3fb950]" if role == "writer" else "[#f0883e]reader[/#f0883e]"
            lc = n["lifecycle"]
            if "InService" in lc:
                lc_str = f"[#3fb950]{lc}[/#3fb950]"
            elif "Terminat" in lc:
                lc_str = f"[#f85149]{lc}[/#f85149]"
            elif "Pending" in lc:
                lc_str = f"[#d29922]{lc}[/#d29922]"
            else:
                lc_str = f"[#8b949e]{lc}[/#8b949e]"
            health = n.get("svc_status", "?")
            h_str = "[#3fb950]ok[/#3fb950]" if health == "ok" else f"[#f85149]{health}[/#f85149]"
            tbl.add_row(
                role_str,
                n["id"],
                n["priv_ip"],
                n.get("pub_ip", "—"),
                h_str,
                lc_str,
                str(n.get("node_id", "—")),
            )

    def _render_volume(self, vol: dict) -> None:
        if not vol:
            self.query_one("#vol-display", Static).update("[#6e7681]no volume data[/#6e7681]")
            return
        lines = [
            f"[#8b949e]vol id    [/#8b949e] [#e6edf3]{vol.get('vol_id','—')}[/#e6edf3]",
            f"[#8b949e]type      [/#8b949e] [#e6edf3]{vol.get('type','—')}[/#e6edf3]   [#8b949e]state[/#8b949e] [#e6edf3]{vol.get('state','—')}[/#e6edf3]",
            f"[#8b949e]size      [/#8b949e] [#e6edf3]{vol.get('size_gib','—')} GiB[/#e6edf3]",
            f"[#8b949e]prov iops [/#8b949e] [#e6edf3]{vol.get('iops',0):,}[/#e6edf3]",
            f"[#8b949e]throughput[/#8b949e] [#e6edf3]{vol.get('throughput',0)} MB/s[/#e6edf3]",
        ]
        self.query_one("#vol-display", Static).update("\n".join(lines))

    def _render_metrics(self, met: dict, db_sz: int) -> None:
        def _fmt(v, suffix=""):
            if v is None:
                return "[dim]—[/dim]"
            if isinstance(v, float):
                return f"[bold]{v:,.1f}[/bold]{suffix}"
            return f"[bold]{v:,}[/bold]{suffix}"

        self.query_one("#m-alb-rps", MetricBox).update_value(_fmt(met.get("alb_rps")))
        self.query_one("#m-alb-p99", MetricBox).update_value(_fmt(met.get("alb_p99_ms"), " ms"))
        self.query_one("#m-ebs-iops", MetricBox).update_value(_fmt(met.get("ebs_iops")))
        self.query_one("#m-ebs-mbs", MetricBox).update_value(_fmt(met.get("ebs_mbs"), " MB/s"))
        db_str = _fmt_bytes(db_sz) if db_sz else "[dim]—[/dim]"
        self.query_one("#m-db-size", MetricBox).update_value(db_str)

        # push to live graph
        graph = self.query_one("#metric-graph", MetricGraph)
        graph.push("alb_rps",    met.get("alb_rps"))
        graph.push("alb_p99_ms", met.get("alb_p99_ms"))
        graph.push("ebs_iops",   met.get("ebs_iops"))
        graph.push("ebs_mbs",    met.get("ebs_mbs"))
        graph.push("db_mib",     db_sz / (1024 * 1024) if db_sz else None)

    def _set_status(self, msg: str, style: str = "") -> None:
        bar = self.query_one("#status-bar", Static)
        ts = datetime.now().strftime("%H:%M:%S")
        txt = f"[{style}]{msg}[/{style}]" if style else msg
        bar.update(f"[dim]{ts}[/dim]  {txt}")

    def _log(self, msg: str) -> None:
        log = self.query_one("#cmd-log", RichLog)
        ts = datetime.now().strftime("%H:%M:%S")
        log.write(f"[dim]{ts}[/dim]  {msg}")
        # strip rich markup for plain-text buffer
        import re as _re
        plain = _re.sub(r"\[/?[^\]]*\]", "", msg)
        self._log_buffer.append(f"{ts}  {plain}")

    # ── Command input ─────────────────────────────────────────────────────────

    @on(Input.Submitted, "#cmd-input")
    def handle_command(self, event: Input.Submitted) -> None:
        raw = event.value.strip()
        if not raw:
            return
        self.query_one("#cmd-input", Input).clear()
        self._log(f"[#d29922]❯ {raw}[/#d29922]")
        parts = raw.split()
        cmd = parts[0].lower()

        if cmd == "help":
            self._show_help()
        elif cmd == "quit" or cmd == "exit":
            self.exit()
        elif cmd == "scale" and len(parts) == 2:
            self._cmd_scale(parts[1])
        elif cmd == "promote" and len(parts) == 2:
            self._cmd_promote(parts[1])
        elif cmd == "kill" and len(parts) == 2:
            self._cmd_kill(parts[1])
        elif cmd == "write" and len(parts) >= 3:
            self._cmd_write(parts[1], " ".join(parts[2:]))
        elif cmd == "read" and len(parts) == 3:
            self._cmd_read(parts[2], parts[1])
        elif cmd == "read" and len(parts) == 2:
            self._cmd_read_alb(parts[1])
        elif cmd == "scan" and len(parts) == 2:
            self._cmd_scan(parts[1])
        elif cmd == "scan" and len(parts) == 1:
            self._cmd_scan_alb()
        elif cmd == "delete" and len(parts) == 2:
            self._cmd_delete(parts[1])
        elif cmd == "resetdb":
            self._cmd_resetdb()
        elif cmd == "copylog":
            self._cmd_copylog(int(parts[1]) if len(parts) == 2 and parts[1].isdigit() else None)
        elif cmd == "stress-test" and len(parts) == 4:
            self._cmd_stress_test(parts[1], parts[2], parts[3])
        else:
            self._log(f"[#f85149]unknown command:[/#f85149] {raw}  — type [#f0883e]help[/#f0883e]")

    def _show_help(self) -> None:
        lines = [
            "[#f0883e]available commands[/#f0883e]",
            "  [#e6edf3]scale <count>[/#e6edf3]                          scale cluster (1–16)",
            "  [#e6edf3]promote <node_id>[/#e6edf3]                      promote reader to writer",
            "  [#e6edf3]kill <node_id>[/#e6edf3]                         terminate a node",
            "  [#e6edf3]write <key> <value>[/#e6edf3]                    write a key/value to writer",
            "  [#e6edf3]read <key>[/#e6edf3]                             read a key via the ALB (any node, fast)",
            "  [#e6edf3]read <node_id> <key>[/#e6edf3]                   read a key from a specific node",
            "  [#e6edf3]scan[/#e6edf3]                                   scan records via the ALB (any node)",
            "  [#e6edf3]scan <node_id>[/#e6edf3]                         scan all records from a node",
            "  [#e6edf3]delete <key>[/#e6edf3]                           delete a key from writer",
            "  [#e6edf3]resetdb[/#e6edf3]                                wipe the RocksDB database",
            "  [#e6edf3]stress-test <size> <loaders> <mins>[/#e6edf3]    run stress test (1gb/10gb/100gb/1tb/2tb)",
            "  [#e6edf3]copylog [n][/#e6edf3]                             copy output log to clipboard (last n lines, or all)",
            "  [#e6edf3]help[/#e6edf3]                                   show this help",
            "  [#e6edf3]quit[/#e6edf3]                                   exit",
        ]
        for l in lines:
            self._log(l)

    def _cmd_copylog(self, last_n: int | None = None) -> None:
        if not self._log_buffer:
            self._log("[#d29922]log is empty[/#d29922]")
            return
        lines = self._log_buffer[-last_n:] if last_n else self._log_buffer
        text = "\n".join(lines)
        try:
            # Fixed, non-user-controlled argument lists; no shell is invoked.
            subprocess.run(["pbcopy"], input=text.encode(), check=True)  # nosec B603 B607 - fixed argument list, no shell, no external input (local clipboard tool)
            self._log(f"[#3fb950]✓ {len(lines)} lines copied to clipboard[/#3fb950]")
        except FileNotFoundError:
            try:
                subprocess.run(["xclip", "-selection", "clipboard"],  # nosec B603 B607 - fixed argument list, no shell, no external input (local clipboard tool)
                               input=text.encode(), check=True)
                self._log(f"[#3fb950]✓ {len(lines)} lines copied to clipboard[/#3fb950]")
            except Exception:
                # Last resort: write to the system temp directory
                path = os.path.join(tempfile.gettempdir(), "rocksdb-tui-log.txt")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
                self._log(f"[#d29922]clipboard unavailable — saved to {path}[/#d29922]")
        except Exception as e:
            self._log(f"[#f85149]copylog failed:[/#f85149] {e}")

    # ── Command implementations ───────────────────────────────────────────────

    def _resolve_node(self, node_id_str: str) -> tuple[str, str] | None:
        """Resolve node_id → (instance_id, pub_ip).
        Accepts: corosync node ID, public IP, or private IP.
        Falls back to IP matching when node IDs are unavailable (e.g. writer is down)."""
        # Try by integer node ID
        try:
            nid = int(node_id_str)
            for n in self.st_nodes:
                if str(n.get("node_id")) == str(nid):
                    return n["id"], n["pub_ip"]
        except ValueError:
            pass

        # Fallback: match by public or private IP
        for n in self.st_nodes:
            if n.get("pub_ip") == node_id_str or n.get("priv_ip") == node_id_str:
                return n["id"], n["pub_ip"]

        self._log(
            f"[#f85149]node '{node_id_str}' not found.[/#f85149] "
            f"[dim]use node ID, public IP, or private IP.[/dim]"
        )
        return None

    @work(thread=True)
    def _cmd_scale(self, count_str: str) -> None:
        try:
            count = int(count_str)
        except ValueError:
            self.call_from_thread(self._log, f"[#f85149]invalid count:[/#f85149] {count_str}")
            return
        if not 1 <= count <= 16:
            self.call_from_thread(self._log, "[#f85149]count must be 1–16[/#f85149]")
            return

        asg = self.st_asg_name
        if not asg:
            self.call_from_thread(self._log, "[#f85149]ASG name not available[/#f85149]")
            return

        self.call_from_thread(self._log, f"scaling to [bold]{count}[/bold] nodes…")
        self.call_from_thread(self._set_status, f"scaling to {count}…", "yellow")
        try:
            asg_client = boto3.client("autoscaling", region_name=REGION)
            asg_client.update_auto_scaling_group(
                AutoScalingGroupName=asg,
                DesiredCapacity=count,
            )
            self.call_from_thread(self._log, f"[#3fb950]✓ ASG desired capacity set to {count}[/#3fb950]")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]scale failed:[/#f85149] {e}")
            return

        # Poll until stable
        self.call_from_thread(self._log, "waiting for cluster to stabilise…")
        writer_ip = next((n["pub_ip"] for n in self.st_nodes if n["role"] == "writer"), "")
        deadline = time.time() + 600
        last_online = -1
        while time.time() < deadline:
            time.sleep(8)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
            nodes = fetch_nodes(asg)
            inservice = sum(1 for n in nodes if "InService" in n.get("lifecycle", ""))
            online = 0
            if writer_ip:
                try:
                    r = httpx.get(f"http://{writer_ip}:8080/cluster/nodes", timeout=5)
                    online = r.json().get("online", 0)
                except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                    pass
            if online != last_online:
                self.call_from_thread(self._log,
                    f"  asg InService: [bold]{inservice}[/bold]  cluster online: [bold]{online}[/bold] / {count}")
                last_online = online
            if inservice >= count and (count == 0 or online >= count):
                break

        self.call_from_thread(self._log, f"[#3fb950]✓ scale to {count} complete[/#3fb950]")
        self.call_from_thread(self._set_status, f"scaled to {count}")
        self._do_refresh()

    def _has_working_cluster(self, pub_ip: str) -> bool:
        """Check if a node has a functioning cluster (corosync online)."""
        try:
            r = httpx.get(f"http://{pub_ip}:8080/cluster/nodes", timeout=5)
            return r.json().get("online", 0) > 0
        except Exception:
            return False

    def _rest_bootstrap_cluster(self, pub_ip: str, priv_ip: str, inst_id: str,
                                log) -> bool:
        """Bootstrap a single-node cluster on a reader via REST endpoint.
        Used when no writer exists and the reader was never added to a cluster.
        Returns True on success."""
        # Get volume ID from SSM
        ssm_client = boto3.client("ssm", region_name=REGION)
        vol_id = ssm_client.get_parameter(
            Name=f"/{CLUSTER_NAME}/volume-id")["Parameter"]["Value"]

        log("  sending bootstrap request…")
        try:
            r = httpx.post(f"http://{pub_ip}:8080/admin/bootstrap", timeout=30, json={
                "priv_ip": priv_ip,
                "instance_id": inst_id,
                "region": REGION,
                "volume_id": vol_id,
                "cluster_name": CLUSTER_NAME,
            })
            log(f"  bootstrap response: {r.text}")
        except Exception as e:
            log(f"  [#d29922]bootstrap request: {e} (may be expected)[/#d29922]")

        # Wait for GFS2 mount + readwrite mode — bootstrap takes ~60-90s
        log("  waiting for cluster bootstrap (this takes ~90s)…")
        for i in range(60):
            try:
                r = httpx.get(f"http://{pub_ip}:8080/health", timeout=5)
                data = r.json()
                if data.get("mode") == "readwrite" and data.get("status") == "ok":
                    log(f"  [#3fb950]bootstrap complete: {r.text}[/#3fb950]")
                    return True
            except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                pass
            time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop

        log("  [#f85149]bootstrap timed out waiting for readwrite mode[/#f85149]")
        return False

    @work(thread=True)
    def _cmd_promote(self, node_id_str: str) -> None:
        resolved = self._resolve_node(node_id_str)
        if not resolved:
            return
        inst_id, pub_ip = resolved

        def log(msg): self.call_from_thread(self._log, msg)

        node = next((n for n in self.st_nodes if n["id"] == inst_id), None)
        if node and node["role"] == "writer":
            self.call_from_thread(self._log, "[#f85149]node is already the writer[/#f85149]")
            return

        # If a healthy writer exists, demote it to reader first
        existing_writer = next((n for n in self.st_nodes
                                if n["role"] == "writer" and n.get("svc_status") == "ok"), None)
        if existing_writer and existing_writer["id"] != inst_id:
            log(f"  demoting existing writer [bold]{existing_writer['priv_ip']}[/bold] to reader…")
            try:
                httpx.post(f"http://{existing_writer['pub_ip']}:8080/admin/demote", timeout=10)
                # Wait for old writer to confirm readonly mode before proceeding
                log("  waiting for old writer to switch to readonly…")
                for _w in range(30):
                    try:
                        h = httpx.get(f"http://{existing_writer['pub_ip']}:8080/health", timeout=5)
                        if h.json().get("mode") == "readonly":
                            log("  old writer confirmed readonly")
                            break
                    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                        pass
                    time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
                else:
                    log("  [#d29922]warning: old writer didn't confirm readonly, proceeding anyway[/#d29922]")

                ec2 = boto3.client("ec2", region_name=REGION)
                ec2.create_tags(Resources=[existing_writer["id"]], Tags=[
                    {"Key": "Name", "Value": "RocksDB-Reader"},
                    {"Key": "rocksdb-role", "Value": "reader"},
                ])
                asg_client = boto3.client("autoscaling", region_name=REGION)
                asg_resp = asg_client.describe_auto_scaling_instances(
                    InstanceIds=[existing_writer["id"]])
                if asg_resp["AutoScalingInstances"]:
                    asg_name = asg_resp["AutoScalingInstances"][0]["AutoScalingGroupName"]
                    asg_client.set_instance_protection(
                        InstanceIds=[existing_writer["id"]],
                        AutoScalingGroupName=asg_name,
                        ProtectedFromScaleIn=False,
                    )
                log(f"  [#3fb950]✓ old writer demoted[/#3fb950]")
            except Exception as e:
                log(f"  [#d29922]warning: could not demote old writer: {e}[/#d29922]")

        self.call_from_thread(self._log, f"promoting node [bold]{node_id_str}[/bold] ({pub_ip})…")
        self.call_from_thread(self._set_status, f"promoting {node_id_str}…", "yellow")

        # Detect writerless cluster: no healthy writer exists anywhere
        has_healthy_writer = any(
            n["role"] == "writer" and n.get("svc_status") == "ok"
            for n in self.st_nodes
        )
        needs_bootstrap = False
        if not has_healthy_writer:
            log("  [#d29922]no healthy writer detected — checking cluster state…[/#d29922]")
            if not self._has_working_cluster(pub_ip):
                log("  [#d29922]node has no working cluster — bootstrapping…[/#d29922]")
                needs_bootstrap = True

        try:
            if needs_bootstrap:
                priv_ip = node.get("priv_ip", "") if node else ""
                if not priv_ip:
                    log("[#f85149]cannot determine private IP for bootstrap[/#f85149]")
                    self.call_from_thread(self._set_status, "promote failed")
                    self._do_refresh()
                    return
                ok = self._rest_bootstrap_cluster(pub_ip, priv_ip, inst_id, log)
                if not ok:
                    log("[#f85149]cluster bootstrap failed[/#f85149]")
                    self.call_from_thread(self._set_status, "promote failed")
                    self._do_refresh()
                    return
                # Bootstrap already set MODE=readwrite and restarted — just wait for health
                log("  waiting for readwrite mode…")
                for _ in range(30):
                    try:
                        r = httpx.get(f"http://{pub_ip}:8080/health", timeout=5)
                        if r.json().get("mode") == "readwrite":
                            log(f"  promoted: {r.text}")
                            break
                    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                        pass
                    time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
            else:
                # Normal promote path — writer exists or node has a working cluster
                # Wait for REST service to be reachable
                log("  waiting for REST service…")
                for _ in range(30):
                    try:
                        r = httpx.get(f"http://{pub_ip}:8080/health", timeout=5)
                        if r.json().get("status") == "ok":
                            log(f"  service ready: {r.text}")
                            break
                    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                        pass
                    time.sleep(5)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop

                # Send promote request (async — service restarts in background)
                log("  sending promote request…")
                try:
                    httpx.post(f"http://{pub_ip}:8080/admin/promote", timeout=30)
                except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                    pass  # timeout is expected — promote restarts the service

                # Wait for readwrite mode — up to 90s
                log("  waiting for readwrite mode…")
                for _ in range(30):
                    try:
                        r = httpx.get(f"http://{pub_ip}:8080/health", timeout=5)
                        if r.json().get("mode") == "readwrite":
                            log(f"  promoted: {r.text}")
                            break
                    except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                        pass
                    time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop

            # Start cluster watcher
            log("  starting cluster watcher…")
            httpx.post(f"http://{pub_ip}:8080/admin/start-watcher", timeout=10)

            # boto3: get instance ID from public IP
            ec2 = boto3.client("ec2", region_name=REGION)
            r = ec2.describe_instances(
                Filters=[{"Name": "ip-address", "Values": [pub_ip]}]
            )
            instance_id = r["Reservations"][0]["Instances"][0]["InstanceId"]
            log(f"  instance: {instance_id}")

            # Set scale-in protection
            asg_client = boto3.client("autoscaling", region_name=REGION)
            asg_resp = asg_client.describe_auto_scaling_instances(InstanceIds=[instance_id])
            asg_name = asg_resp["AutoScalingInstances"][0]["AutoScalingGroupName"]
            asg_client.set_instance_protection(
                InstanceIds=[instance_id],
                AutoScalingGroupName=asg_name,
                ProtectedFromScaleIn=True,
            )
            log("  scale-in protection set")

            # Update SSM + tags
            ssm = boto3.client("ssm", region_name=REGION)
            ssm.put_parameter(
                Name=f"/{CLUSTER_NAME}/writer-instance-id",
                Type="String", Value=instance_id, Overwrite=True,
            )
            ec2.create_tags(Resources=[instance_id], Tags=[
                {"Key": "Name", "Value": "RocksDB-Writer"},
                {"Key": "rocksdb-role", "Value": "writer"},
            ])
            log("  SSM + tags updated")

            # Tag other readers for the cluster watcher to pick up
            if needs_bootstrap:
                other_readers = [n for n in self.st_nodes
                                 if n["id"] != inst_id and n.get("state") == "running"]
                if other_readers:
                    log(f"  tagging {len(other_readers)} reader(s) for cluster watcher pickup…")
                    for rn in other_readers:
                        try:
                            ec2.create_tags(Resources=[rn["id"]], Tags=[
                                {"Key": "rocksdb-join", "Value": CLUSTER_NAME},
                            ])
                        except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                            pass

            # Final health check
            time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
            health = httpx.get(f"http://{pub_ip}:8080/health", timeout=5).text
            log(f"[#3fb950]✓ {pub_ip}: {health}[/#3fb950]")
            self.call_from_thread(self._set_status, f"promoted {node_id_str}")

        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]promote failed:[/#f85149] {e}")
            # Rollback: re-promote old writer if it was demoted
            if existing_writer and existing_writer.get("pub_ip"):
                self.call_from_thread(self._log, "[#d29922]rolling back — re-promoting old writer…[/#d29922]")
                try:
                    httpx.post(f"http://{existing_writer['pub_ip']}:8080/admin/promote", timeout=30)
                    ec2 = boto3.client("ec2", region_name=REGION)
                    ec2.create_tags(Resources=[existing_writer["id"]], Tags=[
                        {"Key": "Name", "Value": "RocksDB-Writer"},
                        {"Key": "rocksdb-role", "Value": "writer"},
                    ])
                except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                    pass
        self._do_refresh()

    @work(thread=True)
    def _cmd_kill(self, node_id_str: str) -> None:
        resolved = self._resolve_node(node_id_str)
        if not resolved:
            return
        inst_id, pub_ip = resolved

        node = next((n for n in self.st_nodes if n["id"] == inst_id), None)
        if node and node["role"] == "writer":
            self.call_from_thread(self._log,
                "[#d29922]warning: killing the writer — promote a reader first[/#d29922]")

        self.call_from_thread(self._log, f"terminating [bold]{inst_id}[/bold] (node {node_id_str})…")
        self.call_from_thread(self._set_status, f"killing {node_id_str}…", "yellow")
        try:
            ec2 = boto3.client("ec2", region_name=REGION)
            ec2.terminate_instances(InstanceIds=[inst_id])
            self.call_from_thread(self._log, f"[#3fb950]✓ terminate issued for {inst_id}[/#3fb950]")
            self.call_from_thread(self._set_status, f"killed {node_id_str}")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]kill failed:[/#f85149] {e}")
        time.sleep(3)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
        self._do_refresh()

    @work(thread=True)
    def _cmd_write(self, key: str, value: str) -> None:
        writer_ip = next((n["pub_ip"] for n in self.st_nodes if n["role"] == "writer"), "")
        if not writer_ip:
            self.call_from_thread(self._log, "[#f85149]no writer found[/#f85149]")
            return
        self.call_from_thread(self._log, f"writing [bold]{key}[/bold] = {value}…")
        for attempt in range(3):
            try:
                # Use a fresh client per request to avoid keep-alive connection reuse issues
                with httpx.Client() as client:
                    r = client.post(
                        f"http://{writer_ip}:8080/put",
                        json={"key": key, "value": value},
                        timeout=10,
                        headers={"Connection": "close"},
                    )
                data = r.json()
                if data.get("status") == "ok":
                    self.call_from_thread(self._log, f"[#3fb950]✓ written:[/#3fb950] {key} = {value}")
                    return
                else:
                    self.call_from_thread(self._log, f"[#d29922]attempt {attempt+1} failed:[/#d29922] {data}")
                    time.sleep(1)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
            except Exception as e:
                self.call_from_thread(self._log, f"[#d29922]attempt {attempt+1} error:[/#d29922] {e}")
                time.sleep(1)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
        self.call_from_thread(self._log, f"[#f85149]write failed after 3 attempts[/#f85149]")

    @work(thread=True)
    def _cmd_read(self, key: str, node_id_str: str) -> None:
        """Read a single key from a specific node via /get."""
        resolved = self._resolve_node(node_id_str)
        if not resolved:
            return
        _, pub_ip = resolved
        self.call_from_thread(self._log, f"reading key [bold]{key}[/bold] from node {node_id_str}…")
        try:
            r = httpx.get(f"http://{pub_ip}:8080/get", params={"key": key}, timeout=10)
            import json as _json
            data = _json.loads(r.content.decode("latin-1"))
            if r.status_code == 200:
                val = data.get("value", "")
                val_display = "".join(c if c.isprintable() else "·" for c in val[:120])
                self.call_from_thread(self._log,
                    f"[#3fb950]✓[/#3fb950] [#f0883e]{data['key']}[/#f0883e] = {val_display}")
            elif r.status_code == 404:
                self.call_from_thread(self._log, f"[#d29922]key not found:[/#d29922] {key}")
            else:
                self.call_from_thread(self._log, f"[#f85149]error:[/#f85149] {data}")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]read error:[/#f85149] {e}")

    @work(thread=True)
    def _cmd_read_alb(self, key: str) -> None:
        """Read a key through the ALB (load-balanced across the fleet via a real
        HTTP call — the production read path). Node-agnostic and fast: no SSM hop.
        Use `read <node_id> <key>` instead to target a specific replica."""
        alb = self.st_alb_dns
        if not alb:
            self.call_from_thread(self._log, "[#f85149]ALB DNS not available yet[/#f85149]")
            return
        self.call_from_thread(self._log, f"reading key [bold]{key}[/bold] via ALB…")
        try:
            r = _real_httpx.get(f"http://{alb}/get", params={"key": key}, timeout=10)
            data = json.loads(r.content.decode("latin-1"))
            if r.status_code == 200:
                val = data.get("value", "")
                val_display = "".join(c if c.isprintable() else "·" for c in val[:120])
                self.call_from_thread(self._log,
                    f"[#3fb950]✓[/#3fb950] [#f0883e]{data['key']}[/#f0883e] = {val_display} [dim](via ALB)[/dim]")
            elif r.status_code == 404:
                self.call_from_thread(self._log, f"[#d29922]key not found:[/#d29922] {key}")
            else:
                self.call_from_thread(self._log, f"[#f85149]error:[/#f85149] {data}")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]ALB read error:[/#f85149] {e}")

    @work(thread=True)
    def _cmd_scan_alb(self) -> None:
        """Scan records through the ALB (lands on whatever node the LB picks, via a
        real HTTP call). Node-agnostic; use `scan <node_id>` to inspect one replica."""
        alb = self.st_alb_dns
        if not alb:
            self.call_from_thread(self._log, "[#f85149]ALB DNS not available yet[/#f85149]")
            return
        self.call_from_thread(self._log, "scanning via [bold]ALB[/bold]…")
        try:
            r = _real_httpx.get(f"http://{alb}/scan", timeout=15)
            records = json.loads(r.content.decode("latin-1")).get("records", [])
            self.call_from_thread(self._log, f"[#3fb950]✓ {len(records)} records[/#3fb950] [dim](via ALB)[/dim]")
            for rec in records[:20]:
                key = rec.get("key", "")
                val = rec.get("value", "")[:80]
                val_display = "".join(c if c.isprintable() else "·" for c in val)
                self.call_from_thread(self._log,
                    f"  [#f0883e]{key}[/#f0883e] = {val_display}")
            if len(records) > 20:
                self.call_from_thread(self._log,
                    f"  [dim]… {len(records)-20} more records[/dim]")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]ALB scan error:[/#f85149] {e}")

    @work(thread=True)
    def _cmd_scan(self, node_id_str: str) -> None:
        """Scan all records from a node via /scan."""
        resolved = self._resolve_node(node_id_str)
        if not resolved:
            return
        _, pub_ip = resolved
        self.call_from_thread(self._log, f"scanning node [bold]{node_id_str}[/bold] ({pub_ip})…")
        try:
            r = httpx.get(f"http://{pub_ip}:8080/scan", timeout=15)
            # Use latin-1 to handle binary values without decode errors
            import json as _json
            records = _json.loads(r.content.decode("latin-1")).get("records", [])
            self.call_from_thread(self._log, f"[#3fb950]✓ {len(records)} records[/#3fb950]")
            for rec in records[:20]:
                key = rec.get("key", "")
                val = rec.get("value", "")[:80]
                # Replace non-printable chars for display
                val_display = "".join(c if c.isprintable() else "·" for c in val)
                self.call_from_thread(self._log,
                    f"  [#f0883e]{key}[/#f0883e] = {val_display}")
            if len(records) > 20:
                self.call_from_thread(self._log,
                    f"  [dim]… {len(records)-20} more records[/dim]")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]scan error:[/#f85149] {e}")

    @work(thread=True)
    def _cmd_delete(self, key: str) -> None:
        """Delete a key from the writer via /delete."""
        writer_ip = next((n["pub_ip"] for n in self.st_nodes if n["role"] == "writer"), "")
        if not writer_ip:
            self.call_from_thread(self._log, "[#f85149]no writer found[/#f85149]")
            return
        self.call_from_thread(self._log, f"deleting key [bold]{key}[/bold]…")
        try:
            with httpx.Client() as client:
                r = client.post(f"http://{writer_ip}:8080/delete",
                               json={"key": key}, timeout=10,
                               headers={"Connection": "close"})
            data = r.json()
            if data.get("status") == "ok":
                self.call_from_thread(self._log, f"[#3fb950]✓ deleted:[/#3fb950] {key}")
            else:
                self.call_from_thread(self._log, f"[#f85149]delete failed:[/#f85149] {data}")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]delete error:[/#f85149] {e}")

    @work(thread=True)
    def _cmd_resetdb(self) -> None:
        writer_ip = next((n["pub_ip"] for n in self.st_nodes if n["role"] == "writer"), "")
        if not writer_ip:
            self.call_from_thread(self._log, "[#f85149]no writer found[/#f85149]")
            return
        self.call_from_thread(self._log, "[#d29922]resetting RocksDB database…[/#d29922]")
        self.call_from_thread(self._set_status, "resetting DB…", "yellow")
        try:
            r = httpx.post(f"http://{writer_ip}:8080/admin/resetdb", timeout=30)
            data = r.json()
            if data.get("status") == "ok":
                self.call_from_thread(self._log, "[#3fb950]✓ database reset complete[/#3fb950]")
                self.call_from_thread(self._set_status, "DB reset")
            else:
                self.call_from_thread(self._log, f"[#f85149]reset failed:[/#f85149] {data}")
        except Exception as e:
            self.call_from_thread(self._log, f"[#f85149]reset error:[/#f85149] {e}")
        self._do_refresh()

    @work(thread=True)
    def _cmd_stress_test(self, dataset_size: str, loader_count: str, duration_mins: str) -> None:
        if self.st_stress_active:
            self.call_from_thread(self._log, "[#d29922]stress test already running[/#d29922]")
            return
        try:
            loaders = int(loader_count)
            mins = int(duration_mins)
        except ValueError:
            self.call_from_thread(self._log, "[#f85149]invalid args — usage: stress-test <size> <loaders> <mins>[/#f85149]")
            return

        self.st_stress_active = True
        duration_secs = mins * 60

        def log(msg): self.call_from_thread(self._log, msg)
        def status(msg): self.call_from_thread(self._set_status, msg, "yellow")

        keys_map = {"1gb": 1_000_000, "10gb": 10_000_000, "100gb": 100_000_000,
                    "1tb": 1_000_000_000, "2tb": 2_000_000_000}
        num_keys = keys_map.get(dataset_size.lower(), 1_000_000)

        ec2_client  = boto3.client("ec2",          region_name=REGION)
        asg_client  = boto3.client("autoscaling",  region_name=REGION)
        cw_client   = boto3.client("cloudwatch",   region_name=REGION)
        elb_client  = boto3.client("elbv2",        region_name=REGION)

        try:
            writer_ip = next((n["pub_ip"] for n in self.st_nodes if n["role"] == "writer"), "")
            if not writer_ip:
                log("[#f85149]no writer found[/#f85149]"); return

            # ── Step 1: Preload via SSM ───────────────────────────────────────
            # REST/SSH are not exposed to the internet (SG lockdown); drive the
            # writer on-box via SSM Run Command instead of paramiko SSH.
            log("\n[#f0883e]── step 1: preloading data ──[/#f0883e]")
            status(f"preloading {dataset_size} ({num_keys:,} keys)…")
            import base64 as _b64
            wiid = next((n["id"] for n in self.st_nodes if n["role"] == "writer"), "") or _resolve_iid(writer_ip)
            if not wiid:
                log("[#f85149]could not resolve writer instance id[/#f85149]"); return

            def ssm_exec(cmd: str, wait: int = 120) -> str:
                """Run a command on the writer via SSM; return stdout ('' on failure)."""
                return _ssm_run(wiid, cmd, wait=wait)

            # Disk-space guard. Values are INCOMPRESSIBLE random bytes, so on-disk size
            # ≈ num_keys × (value + key + overhead). Refuse if it won't fit the volume —
            # this is what made `1tb`/`2tb` hang/ENOSPC on the 1000 GiB volume.
            req_gib = (num_keys * (1024 + 32)) / (1024 ** 3)
            vol = self.st_volume or fetch_volume(self.st_volume_id)
            vol_gib = float(vol.get("size_gib") or 0)
            log(f"  dataset ≈ {req_gib:,.0f} GiB on disk (incompressible) · volume {vol_gib:,.0f} GiB")
            if vol_gib and req_gib > vol_gib * 0.9:
                log(f"[#f85149]  refusing: {dataset_size} needs ~{req_gib:,.0f} GiB but the volume is "
                    f"{vol_gib:,.0f} GiB. Pick a smaller size (≤ ~{int(vol_gib*0.9/1.03):,} GiB of keys) "
                    f"or grow the volume.[/#f85149]")
                return

            sst_src = os.path.join(os.path.dirname(__file__), "stress-test", "sst_generator.cc")
            runner = (
                "#!/bin/bash\n"
                "ulimit -n 524288\n"
                "/tmp/sst_generator /data/rocksdb/db --destroy > /tmp/preload.log 2>&1\n"
                f"/tmp/sst_generator /data/rocksdb/db {num_keys} 1024 /data/rocksdb/sst_bulk 1000000 >> /tmp/preload.log 2>&1\n"
                "echo PRELOAD_EXIT_$? >> /tmp/preload.log\n"
            )
            with open(sst_src, "rb") as _f:
                src_b64 = _b64.b64encode(_f.read()).decode()
            runner_b64 = _b64.b64encode(runner.encode()).decode()
            ssm_exec(f"echo {src_b64} | base64 -d > /tmp/sst_generator.cc; "
                     f"echo {runner_b64} | base64 -d > /tmp/preload_runner.sh", wait=120)
            log("  uploaded sst_generator.cc + runner")

            log("  compiling sst_generator…")
            out = ssm_exec(
                "g++ -O2 -std=c++17 /tmp/sst_generator.cc -I/usr/local/include -L/usr/local/lib "
                "-lrocksdb -lsnappy -lz -llz4 -lzstd -ldl -lpthread -o /tmp/sst_generator && echo __COMPILE_OK__", wait=600)
            if "__COMPILE_OK__" not in out:
                log(f"[#f85149]  compile failed: {out[-200:]}[/#f85149]"); return

            out = ssm_exec(
                "sudo systemctl stop rocksdb.service && sleep 2 && sudo chmod 777 /data/rocksdb/db && "
                "sudo mkdir -p /data/rocksdb/sst_bulk && sudo chmod 777 /data/rocksdb/sst_bulk && echo __PREP_OK__", wait=120)
            if "__PREP_OK__" not in out:
                log(f"[#f85149]  prep failed: {out[-200:]}[/#f85149]")
                ssm_exec("sudo systemctl start rocksdb.service", wait=60); return

            # Launch the generator DETACHED (systemd-run) so it survives the SSM channel,
            # then stream progress from /tmp/preload.log instead of blocking silently.
            ssm_exec("sudo systemd-run --unit=rocksdb-preload --collect bash /tmp/preload_runner.sh", wait=60)
            log("  generating SSTs — live progress (this can take many minutes):")

            preload_cap = max(1200, int(num_keys / 150000) + 600)  # generous wall-clock cap
            pstart = time.time(); last_line = ""; preload_ok = False
            while time.time() - pstart < preload_cap:
                time.sleep(15)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
                rows = ssm_exec(
                    "tail -n 1 /tmp/preload.log 2>/dev/null; "
                    "grep -q PRELOAD_EXIT_ /tmp/preload.log 2>/dev/null && echo __DONE__", wait=60).splitlines()
                done = "__DONE__" in rows
                prog = next((r for r in rows if r != "__DONE__"), "")
                if prog and prog != last_line:
                    log(f"  {prog[-160:]}"); last_line = prog
                if done:
                    code = ssm_exec("grep -oP 'PRELOAD_EXIT_\\K[0-9]+' /tmp/preload.log | tail -1", wait=60).strip()
                    if code == "0":
                        preload_ok = True; log("  [#3fb950]preload complete[/#3fb950]")
                    else:
                        tail = ssm_exec("tail -n 5 /tmp/preload.log", wait=60)
                        log(f"[#f85149]  preload failed (exit {code}): {tail[-300:]}[/#f85149]")
                    break
            if not preload_ok:
                log(f"[#f85149]  preload did not finish within {preload_cap//60} min — aborting[/#f85149]")
                ssm_exec("sudo systemctl start rocksdb.service", wait=60); return

            ssm_exec("sudo rm -rf /data/rocksdb/sst_bulk /tmp/sst_generator /tmp/sst_generator.cc /tmp/preload_runner.sh", wait=120)
            ssm_exec("sudo systemctl start rocksdb.service", wait=60)

            # Wait for writer healthy
            log("  waiting for writer to be ready…")
            for _ in range(30):
                try:
                    r = httpx.get(f"http://{writer_ip}:8080/health", timeout=5)
                    if r.json().get("mode") == "readwrite":
                        log(f"  [#3fb950]writer ready[/#3fb950]"); break
                except Exception: pass  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                time.sleep(5)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop

            # ── Step 2: Scale to 16 ──────────────────────────────────────────
            log("\n[#f0883e]── step 2: scaling to 16 nodes ──[/#f0883e]")
            status("scaling to 16…")
            asg_client.update_auto_scaling_group(
                AutoScalingGroupName=self.st_asg_name, DesiredCapacity=16)
            log("  ASG desired=16 set")

            deadline = time.time() + 900
            while time.time() < deadline:
                time.sleep(10)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
                try:
                    online = httpx.get(f"http://{writer_ip}:8080/cluster/nodes", timeout=5).json().get("online", 0)
                    log(f"  cluster online: {online}/16")
                    if online >= 16: break
                except Exception: pass  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
            # Proceed even if not all 16 joined — partial cluster is fine for stress test
            try:
                online = httpx.get(f"http://{writer_ip}:8080/cluster/nodes", timeout=5).json().get("online", 0)
                log(f"  proceeding with {online}/16 nodes online")
            except Exception:  # nosec B110 - best-effort cleanup/status poll; the exception is intentionally non-fatal
                pass

            # ── Step 3: Launch loaders ───────────────────────────────────────
            log(f"\n[#f0883e]── step 3: launching {loaders} loader instances ──[/#f0883e]")
            status(f"launching {loaders} loaders…")

            # Get VPC/subnet (different AZ from cluster)
            vpc_id = self.st_asg_name and _cfn_output("VpcId")
            subnets = ec2_client.describe_subnets(
                Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                         {"Name": "mapPublicIpOnLaunch", "Values": ["true"]}]
            )["Subnets"]
            subnet_id = next((s["SubnetId"] for s in subnets
                              if s["AvailabilityZone"] != f"{REGION}a"), subnets[0]["SubnetId"])

            # Loader SG
            sgs = ec2_client.describe_security_groups(
                Filters=[{"Name": "group-name", "Values": ["rocksdb-loader-sg"]},
                         {"Name": "vpc-id", "Values": [vpc_id]}]
            )["SecurityGroups"]
            if sgs:
                loader_sg = sgs[0]["GroupId"]
                log(f"  reusing loader SG: {loader_sg}")
            else:
                loader_sg = ec2_client.create_security_group(
                    GroupName="rocksdb-loader-sg",
                    Description="RocksDB load generator",
                    VpcId=vpc_id,
                )["GroupId"]
                try:
                    ec2_client.authorize_security_group_egress(
                        GroupId=loader_sg,
                        IpPermissions=[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}],
                    )
                except ec2_client.exceptions.ClientError as e:
                    if "InvalidPermission.Duplicate" not in str(e):
                        raise
                log(f"  created loader SG: {loader_sg}")

            ami = ec2_client.describe_images(
                Owners=["099720109477"],
                Filters=[{"Name": "name", "Values": ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]},
                         {"Name": "state", "Values": ["available"]}],
            )["Images"]
            ami_id = sorted(ami, key=lambda x: x["CreationDate"])[-1]["ImageId"]

            # Guard against the EC2 vCPU quota — c5.4xlarge is 16 vCPU each.
            vcpus_needed = loaders * 16
            quota_val = None
            try:
                _sq = boto3.client("service-quotas", region_name=REGION)
                quota_val = _sq.get_service_quota(ServiceCode="ec2", QuotaCode="L-1216C47")["Quota"]["Value"]
            except Exception:
                quota_val = None
            if quota_val is not None and vcpus_needed > quota_val:
                log(f"[#f85149]  {loaders} × c5.4xlarge = {vcpus_needed} vCPUs exceeds your On-Demand "
                    f"vCPU quota ({int(quota_val)}). Use at most {int(quota_val)//16} loaders.[/#f85149]")
                return
            if quota_val is None and loaders > 20:
                log(f"[#d29922]  note: {loaders} loaders = {vcpus_needed} vCPUs — ensure your quota allows it[/#d29922]")

            alb_dns = self.st_alb_dns
            ud = f"""#!/bin/bash
apt-get update -q && apt-get install -y -q wrk
cat > /tmp/rk.lua << 'LUA'
math.randomseed(os.time()+math.random(1000000))
local n={num_keys}
function request() return wrk.format("GET","/get?key=stress%3A"..string.format("%016d",math.random(0,n-1))) end
LUA
wrk -t16 -c1000 -d{duration_secs}s --script /tmp/rk.lua --latency http://{alb_dns} > /tmp/results.txt 2>&1
"""
            # One atomic run_instances (MinCount=1 → best-effort if capacity is short).
            loader_ids = []
            try:
                resp = ec2_client.run_instances(
                    ImageId=ami_id, InstanceType="c5.4xlarge",
                    NetworkInterfaces=[{
                        "DeviceIndex": 0,
                        "SubnetId": subnet_id,
                        "Groups": [loader_sg],
                        "AssociatePublicIpAddress": True,
                    }],
                    MinCount=1, MaxCount=loaders,
                    UserData=ud,
                    TagSpecifications=[{"ResourceType": "instance",
                                        "Tags": [{"Key": "Name", "Value": "rocksdb-loader"}]}],
                )
                loader_ids = [i["InstanceId"] for i in resp["Instances"]]
                log(f"  [#3fb950]launched {len(loader_ids)}/{loaders} loaders[/#3fb950]")
            except Exception as e:
                log(f"[#f85149]  loader launch failed: {e}[/#f85149]")
            if not loader_ids:
                log("[#f85149]  no loaders launched — aborting[/#f85149]"); return

            # Save loader IDs for teardown. Path is fixed at /tmp/loader_instance_ids.txt
            # because the stress-test shell scripts (04_run_stress.sh, 05_teardown.sh)
            # read this exact path. Contents are non-sensitive EC2 instance IDs.
            with open("/tmp/loader_instance_ids.txt", "w", encoding="utf-8") as f:  # nosec B108 - non-sensitive instance IDs; path fixed by the stress-test shell-script contract  # nosemgrep: hardcoded-tmp-path - same reason
                f.write("\t".join(loader_ids))

            # ── Step 4: Monitor ──────────────────────────────────────────────
            log(f"\n[#f0883e]── step 4: monitoring ({mins} min, every 30s) ──[/#f0883e]")
            status(f"stress test running — {mins} min")

            alb_arn = _get_alb_arn()
            suffix  = _alb_suffix(alb_arn)
            start   = time.time()
            while time.time() - start < duration_secs:
                time.sleep(30)  # nosemgrep: arbitrary-sleep - intentional poll/refresh pacing in the TUI loop
                elapsed = int(time.time() - start)
                met = fetch_metrics(suffix, self.st_volume_id)
                try:
                    online = httpx.get(f"http://{writer_ip}:8080/cluster/nodes", timeout=5).json().get("online", "?")
                except Exception:
                    online = "?"
                log(f"  [dim]+{elapsed}s[/dim]  nodes=[bold]{online}[/bold]  "
                    f"RPS=[bold]{met.get('alb_rps','?')}[/bold]  "
                    f"p99=[bold]{met.get('alb_p99_ms','?')}ms[/bold]  "
                    f"IOPS=[bold]{met.get('ebs_iops','?')}[/bold]  "
                    f"MB/s=[bold]{met.get('ebs_mbs','?')}[/bold]")
                self._do_refresh()

            # ── Step 5: Teardown loaders ─────────────────────────────────────
            log("\n[#f0883e]── step 5: terminating loaders ──[/#f0883e]")
            status("tearing down loaders…")
            if loader_ids:
                ec2_client.terminate_instances(InstanceIds=loader_ids)
                log(f"  [#3fb950]✓ {len(loader_ids)} tracked loaders terminated[/#3fb950]")

            # Also terminate any stray loaders by tag (match shell teardown)
            stray = ec2_client.describe_instances(
                Filters=[{"Name": "tag:Name", "Values": ["rocksdb-loader"]},
                         {"Name": "instance-state-name", "Values": ["running", "pending"]}]
            )
            stray_ids = [i["InstanceId"] for r in stray["Reservations"] for i in r["Instances"]
                        if i["InstanceId"] not in loader_ids]
            if stray_ids:
                ec2_client.terminate_instances(InstanceIds=stray_ids)
                log(f"  [#3fb950]✓ {len(stray_ids)} stray loaders terminated[/#3fb950]")

            log("[bold #3fb950]✓ stress test complete[/bold #3fb950]")
            self.call_from_thread(self._set_status, "stress test complete")

        except Exception as e:
            log(f"[#f85149]stress test error:[/#f85149] {e}")
        finally:
            self.st_stress_active = False
            self._do_refresh()


if __name__ == "__main__":
    RocksDBTUI().run()
