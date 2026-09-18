#!/usr/bin/env python3
"""Generate a self-contained HTML performance report for a pf-perf test run.

Page 1 aggregates the whole run: throughput over time, response time (avg+p90)
over time, and engine CPU over time — all on one shared time axis so a vertical
line crosses the same moment in every chart. Page 2 holds per-agent details.

Inputs (under results/<run>/):
  agent-<i>-metrics.json  k6 streaming NDJSON (per-request latency, http_reqs)
  agent-<i>.log           k6 end-of-run summaries
  ../pod-usage-<UTC>.csv  engine CPU/memory samples from make monitor
Outputs:
  results/<run>/report.html  one file, no external resources
"""
import gzip
import io
import json
import math
import re
import sys
from datetime import datetime, timezone
from html import escape
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"
THRESHOLD_P95_MS = 500.0


# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------

def parse_k6_summary(path):
    """End-of-run summary metrics from one k6 agent log."""
    text = path.read_text(errors="replace")
    out = {"agent": path.stem}
    patterns = {
        "reqs": r"http_reqs\.+: +(\d+) +([\d.]+)/s",
        "success": r"token_exchange_success\.+: +([\d.]+)% +(\d+) out of (\d+)",
        # k6 prints durations >= 1s with an "s" suffix ("1.19s"), < 1s as ms.
        "latency": (r"token_exchange_latency\.+: +avg=([\d.]+)(m?s) +min=([\d.]+)(m?s)"
                    r" +med=([\d.]+)(m?s) +max=([\d.]+)(m?s) +p\(90\)=([\d.]+)(m?s) +p\(95\)=([\d.]+)(m?s)"),
        # per-agent dropped iterations (load shedding by the VU cap)
        "dropped": r"dropped_iterations\.+: +(\d+)",
        # the configured scenario rate, from the scenario description line
        "target_rate": r"token_exchange: +([\d.]+) +iterations/s",
        # the warmup duration, from the warmup scenario line ("30s")
        "warmup_cfg": r"warmup: +[\d.]+ +iterations/s for +([\d.]+[sm])",
    }
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            if key == "warmup_cfg":  # duration strings like "30s" / "5m"
                out[key] = list(m.groups())
            elif key == "latency":
                # interleave value/unit groups; normalize s to ms
                vals = []
                g = m.groups()
                for i in range(0, len(g), 2):
                    n = float(g[i])
                    if g[i + 1] == "s":
                        n *= 1000.0
                    vals.append(n)
                out[key] = vals
            else:
                out[key] = [float(g) for g in m.groups()]
    return out


def parse_k6_metrics_json(path):
    """Parse k6's streaming NDJSON into per-second series.

    Returns dict with:
      dur_avg_s, dur_p90_s, dur_p95_s: [(t_sec, value_ms), ...]
      req_rate: [(t_sec, reqs_per_s), ...]  (derivative of cumulative count)
      total_requests: int
      t0: first absolute timestamp (str)
    """
    if path.stat().st_size > 512 * 1024 * 1024:
        print(f"warning: {path} unexpectedly large; skipping", file=sys.stderr)
        return None
    durations = []
    subtimings = {}  # metric -> [(ts, ms)] for connecting/tls_handshaking/waiting/sending/receiving
    warmup_points = 0
    sub_metric_names = {"http_req_connecting", "http_req_tls_handshaking",
                        "http_req_waiting", "http_req_sending", "http_req_receiving"}
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or '"Point"' not in line.replace(" ", ""):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") != "Point":
                continue
            metric = ev.get("metric", "")
            if metric != "http_req_duration" and metric not in sub_metric_names:
                continue
            data = ev.get("data", {})
            # Warmup traffic (phase=warmup scenario) is excluded from the
            # measured series — it exists to prime connections and JIT.
            if data.get("tags", {}).get("phase") == "warmup":
                warmup_points += 1
                continue
            t = data.get("time", "")
            try:
                ts = datetime.fromisoformat(t.replace("Z", "+00:00"))
            except ValueError:
                continue
            # k6's json output already reports trend durations in milliseconds.
            if metric == "http_req_duration":
                durations.append((ts, float(data.get("value", 0))))
            else:
                subtimings.setdefault(metric, []).append((ts, float(data.get("value", 0))))
    if not durations:
        return None
    durations.sort(key=lambda x: x[0])
    t0 = durations[0][0]

    # Bucket per second: avg + p90 over the requests in that second.
    buckets = {}
    for ts, ms in durations:
        sec = int((ts - t0).total_seconds())
        buckets.setdefault(sec, []).append(ms)
    dur_avg, dur_p90, dur_p95 = [], [], []
    for sec in sorted(buckets):
        vals = sorted(buckets[sec])
        n = len(vals)
        dur_avg.append((sec, sum(vals) / n))
        dur_p90.append((sec, vals[min(n - 1, int(math.ceil(0.90 * n)) - 1)]))
        dur_p95.append((sec, vals[min(n - 1, int(math.ceil(0.95 * n)) - 1)]))

    # Throughput: requests per second (count per bucket), smoothed over 5s.
    req_rate = [(sec, len(buckets[sec])) for sec in sorted(buckets)]
    # Sub-timings (connecting / tls_handshaking / waiting / sending /
    # receiving): per-second means, pooled across this agent's requests.
    sub_series = {}
    for name, pts in subtimings.items():
        tb = {}
        for ts, ms in pts:
            tb.setdefault(int((ts - t0).total_seconds()), []).append(ms)
        sub_series[name] = [(sec, sum(v) / len(v)) for sec, v in sorted(tb.items())]
    return {
        "dur_avg_s": dur_avg,
        "dur_p90_s": dur_p90,
        "dur_p95_s": dur_p95,
        "req_rate": req_rate,
        # Raw per-second values, for exact pooling across agents on page 1.
        "buckets_ms": buckets,
        "subtimings": sub_series,
        "total_requests": len(durations),
        "warmup_points": warmup_points,
        "t0": t0,
    }


def parse_k6_progress_lines(path):
    """Fallback: derive cumulative->per-second iteration counts from the k6
    progress lines ("running (0m03.0s), 01/25 VUs, 149 complete ...").
    Returns [(sec, cumulative_iters)] or []."""
    pts = []
    for m in re.finditer(r"running \((\d+)m([\d.]+)s\), \d+/\d+ VUs, (\d+) complete", path.read_text(errors="replace")):
        sec = int(m.group(1)) * 60 + float(m.group(2))
        pts.append((sec, int(m.group(3))))
    pts.sort()
    return pts


def pooled_percentile(series, q=0.95):
    """True pooled percentile (ms) over every measured-phase raw datapoint in
    all agents' per-second buckets — recomputable by a reviewer from the
    raw NDJSON. Returns None when no datapoints exist."""
    all_ms = [ms for s in series.values() for vals in s["buckets_ms"].values() for ms in vals]
    if not all_ms:
        return None
    all_ms.sort()
    return all_ms[min(len(all_ms) - 1, int(math.ceil(q * len(all_ms))) - 1)]


def pooled_subtiming_means(series):
    """Pooled per-second mean of each k6 sub-timing (connecting, tls_handshaking,
    waiting, sending, receiving) across all agents: {metric: [(sec, ms)]}."""
    pooled = {}
    for s in series.values():
        for name, pts in s.get("subtimings", {}).items():
            d = pooled.setdefault(name, {})
            for sec, ms in pts:
                d.setdefault(sec, []).append(ms)
    return {name: [(sec, sum(v) / len(v)) for sec, v in sorted(d.items())]
            for name, d in pooled.items()}


def parse_usage_csv(path):
    """Parse the monitor CSV into per-name series.

    Supports both layouts:
      pod-only (legacy):  timestamp,pod,cpu,memory
      current:            timestamp,kind,name,cpu,memory_or_pct   (kind pod|node)

    Returns {name: [(ts, cpu_m, mem_or_pct, kind), ...]}.
    """
    series = {}
    with open(path, errors="replace") as f:
        header = f.readline()
        has_kind = header.strip().split(",")[1:2] == ["kind"]
        for line in f:
            parts = line.strip().split(",")
            if has_kind:
                if len(parts) != 5:
                    continue
                ts, kind, name, cpu, last = parts
            else:
                if len(parts) != 4:
                    continue
                ts, name, cpu, last = parts
                kind = "pod"
            cpu_m = int(cpu.rstrip("m")) if cpu.endswith("m") else 0
            if last.endswith("Mi"):
                last_v = int(last[:-2])
            elif last.endswith("Gi"):
                last_v = int(float(last[:-2]) * 1024)
            elif last.endswith("%"):  # node CPU percentage
                last_v = float(last[:-1])
            else:
                last_v = 0
            series.setdefault(name, []).append((ts, cpu_m, last_v, kind))
    return series


# --------------------------------------------------------------------------
# series helpers
# --------------------------------------------------------------------------

def moving_average(points, window):
    """points: [(t, v)] sorted by t -> centered moving average of v over `window` samples."""
    if not points or window <= 1:
        return points
    out = []
    half = window // 2
    for i, (t, _) in enumerate(points):
        lo, hi = max(0, i - half), min(len(points), i + half + 1)
        out.append((t, sum(v for _, v in points[lo:hi]) / (hi - lo)))
    return out


def to_seconds(points, t0):
    """[(datetime|str, v)] -> [(float seconds since t0, v)]."""
    out = []
    if t0.tzinfo is None:
        t0 = t0.replace(tzinfo=timezone.utc)
    for t, v in points:
        if isinstance(t, str):
            t = datetime.fromisoformat(t.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        out.append(((t - t0).total_seconds(), v))
    return out


# --------------------------------------------------------------------------
# chart rendering (inline SVG, no JS)
# --------------------------------------------------------------------------

PALETTE = ["#2563eb", "#dc2626", "#059669", "#d97706", "#7c3aed"]


def line_chart(title, series_list, y_unit, y_max=None, height=200, width=860,
               y_label_every=3, x_grid_every=30, area_fill=False):
    """series_list: [(name, color, [(x, y), ...])]. Shared x axis in seconds."""
    all_pts = [(x, y) for _, _, pts in series_list for x, y in pts]
    if not all_pts:
        return f"<p class='muted'>No data for {escape(title)}.</p>"
    x_max = max(x for x, _ in all_pts) or 1
    y_max = y_max or max(y for _, y in all_pts) * 1.15 or 1
    pad_l, pad_r, pad_t, pad_b = 48, 14, 14, 28
    w = width - pad_l - pad_r
    h = height - pad_t - pad_b

    def X(x):
        return pad_l + x / x_max * w

    def Y(y):
        return pad_t + h - min(1.0, y / y_max) * h

    paths = []
    for si, (name, color, pts) in enumerate(series_list):
        if len(pts) < 2:
            continue
        d = "M" + " L".join(f"{X(x):.1f},{Y(y):.1f}" for x, y in pts)
        if area_fill and len(series_list) == 1:
            d += f" L{X(pts[-1][0]):.1f},{Y(0):.1f} L{X(pts[0][0]):.1f},{Y(0):.1f} Z"
            gid = f"grad{si}"
            defs = (f'<linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">'
                    f'<stop offset="0%" stop-color="{color}" stop-opacity="0.25"/>'
                    f'<stop offset="100%" stop-color="{color}" stop-opacity="0.02"/></linearGradient>')
            paths.append(f'<defs>{defs}</defs><path d="{d}" fill="url(#{gid})" stroke="{color}" stroke-width="1.8"/>')
        else:
            paths.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.8" '
                         f'stroke-linecap="round" stroke-linejoin="round"/>')

    grid = []
    n_grid = 4
    for i in range(n_grid + 1):
        yv = y_max * i / n_grid
        grid.append(
            f'<line x1="{pad_l}" y1="{Y(yv):.1f}" x2="{width - pad_r}" y2="{Y(yv):.1f}" '
            f'stroke="currentColor" stroke-opacity="0.07"/>'
            f'<text x="{pad_l - 8}" y="{Y(yv) + 3:.1f}" text-anchor="end" class="tick">{yv:.0f}</text>'
        )
    xticks = []
    t = 0
    while t <= x_max:
        mm, ss = divmod(int(t), 60)
        xticks.append(
            f'<line x1="{X(t):.1f}" y1="{pad_t}" x2="{X(t):.1f}" y2="{pad_t + h}" '
            f'stroke="currentColor" stroke-opacity="0.05"/>'
            f'<text x="{X(t):.1f}" y="{height - 8}" text-anchor="middle" class="tick">{mm}:{ss:02d}</text>'
        )
        t += x_grid_every

    legend = "".join(
        f'<span class="lg"><i style="background:{color}"></i>{escape(name)}</span>'
        for name, color, _ in series_list
    )
    return f"""
<figure class="chart">
  <figcaption>{escape(title)} <span class="unit">{escape(y_unit)}</span></figcaption>
  <svg viewBox="0 0 {width} {height}" class="svg" role="img" aria-label="{escape(title)}">
    {''.join(grid)}{''.join(xticks)}{''.join(paths)}
  </svg>
  <div class="legend">{legend}</div>
</figure>"""


def stacked_area_chart(title, series_list, y_unit, height=200, width=860):
    """series_list stacked bottom-up; shared x axis in seconds. Readable CPU chart."""
    all_pts = [(x, y) for _, _, pts in series_list for x, y in pts]
    if not all_pts:
        return f"<p class='muted'>No data for {escape(title)}.</p>"
    x_max = max(x for x, _ in all_pts) or 1
    total_max = max(
        sum(y for _, _, pts in series_list for x2, y in pts if abs(x2 - x) < 1)
        for x, _ in all_pts
    )
    y_max = total_max * 1.15 or 1
    pad_l, pad_r, pad_t, pad_b = 48, 14, 14, 28
    w = width - pad_l - pad_r
    h = height - pad_t - pad_b

    def X(x):
        return pad_l + x / x_max * w

    def Y(y):
        return pad_t + h - min(1.0, y / y_max) * h

    # interpolate every series onto a common second grid, then stack
    grid = list(range(0, int(x_max) + 1))

    def interp(pts):
        d = dict((int(x), y) for x, y in pts)
        return [d.get(g, d[max(k for k in d if k <= g)] if any(k <= g for k in d)
                      else d[min(k for k in d)]) for g in grid]

    stacked = []
    cum = [0.0] * len(grid)
    areas = []
    for name, color, pts in series_list:
        vals = interp(pts)
        top = [c + v for c, v in zip(cum, vals)]
        d = f"M{X(grid[0]):.1f},{Y(cum[0]):.1f} " + " L".join(
            f"{X(g):.1f},{Y(t):.1f}" for g, t in zip(grid, top))
        d += " L" + " L".join(f"{X(g):.1f},{Y(c):.1f}" for g, c in
                              zip(reversed(grid), reversed(cum))) + " Z"
        areas.append(f'<path d="{d}" fill="{color}" fill-opacity="0.35" stroke="{color}" stroke-width="1"/>')
        cum = top

    gridl = []
    for i in range(5):
        yv = y_max * i / 4
        gridl.append(
            f'<line x1="{pad_l}" y1="{Y(yv):.1f}" x2="{width - pad_r}" y2="{Y(yv):.1f}" '
            f'stroke="currentColor" stroke-opacity="0.08"/>'
            f'<text x="{pad_l - 6}" y="{Y(yv) + 3:.1f}" text-anchor="end" class="tick">{yv:.0f}</text>'
        )
    xticks = []
    t = 0
    while t <= x_max:
        mm, ss = divmod(int(t), 60)
        xticks.append(
            f'<line x1="{X(t):.1f}" y1="{pad_t}" x2="{X(t):.1f}" y2="{pad_t + h}" '
            f'stroke="currentColor" stroke-opacity="0.06"/>'
            f'<text x="{X(t):.1f}" y="{height - 8}" text-anchor="middle" class="tick">{mm}:{ss:02d}</text>'
        )
        t += 30
    legend = "".join(
        f'<span class="lg"><i style="background:{color}"></i>{escape(name)}</span>'
        for name, color, _ in series_list
    )
    return f"""
<figure class="chart">
  <figcaption>{escape(title)} <span class="unit">({escape(y_unit)}, stacked)</span></figcaption>
  <svg viewBox="0 0 {width} {height}" class="svg" role="img" aria-label="{escape(title)}">
    {''.join(gridl)}{''.join(xticks)}{''.join(areas)}
    <line x1="{pad_l}" y1="{pad_t + h}" x2="{width - pad_r}" y2="{pad_t + h}" stroke="currentColor" stroke-opacity="0.3"/>
    <line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{pad_t + h}" stroke="currentColor" stroke-opacity="0.3"/>
  </svg>
  <div class="legend">{legend}</div>
</figure>"""


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        runs = sorted((p for p in RESULTS.iterdir() if p.is_dir()), reverse=True)
        if runs:
            sys.argv.append(runs[0].name)
            print(f"No RUN given; using newest: {runs[0].name}")
        else:
            print(__doc__)
            sys.exit(1)

    run_dir = RESULTS / sys.argv[1]
    # Per-run metadata captured at test launch (env.json, written by
    # run-in-cluster.sh): resolved envs, profile, thresholds. Thresholds
    # govern the verdict — the same values k6 gated on.
    env_meta = {}
    env_json = run_dir / "env.json"
    if env_json.is_file():
        env_meta = json.loads(env_json.read_text())
    if not run_dir.is_dir():
        print(f"Run not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    summaries = [parse_k6_summary(p) for p in sorted(run_dir.glob("agent-*.log"))
                 if not p.name.endswith("-metrics.json")]
    summaries = [s for s in summaries if "latency" in s]

    metric_files = sorted(run_dir.glob("agent-*-metrics.json"))
    fixture_warning = False
    stream_truncated = False
    stream_gaps = []
    series = {}
    for mf in metric_files:
        parsed = parse_k6_metrics_json(mf)
        if parsed:
            agent = mf.stem.replace("-metrics", "")
            series[agent] = parsed
            summ = next((s for s in summaries if s["agent"] == agent), None)
            if summ and "reqs" in summ:
                gap = 1 - parsed["total_requests"] / max(1, summ["reqs"][0])
                if gap > 0.5:
                    fixture_warning = True  # counts wildly off: likely synthetic data
                elif gap > 0.02:
                    # Streams are snapshotted while pods run, so the last few
                    # seconds of each agent's stream can be missing.
                    stream_truncated = True

    usage_files = sorted(RESULTS.glob("pod-usage-*.csv"))
    usage = parse_usage_csv(usage_files[-1]) if usage_files else {}
    engine_series = {p: s for p, s in usage.items() if "engine" in p and s[0][3] == "pod"}
    node_series = {p: s for p, s in usage.items() if s[0][3] == "node"}

    # Time base: k6 series t0 if present, else CSV start.
    t0 = min((s["t0"] for s in series.values()), default=None)
    if t0 is None and engine_series:
        first = min(s[0][0] for s in engine_series.values())
        t0 = datetime.fromisoformat(first.replace("Z", "+00:00"))

    # ---- page 1 series: the platform as a whole, pooled across all agents ----
    # Every agent measures the same platform; pooling every raw datapoint gives
    # the aggregate view (total req/s, platform-wide avg/p90 per second) rather
    # than per-agent slices. Per-agent series stay on the details page.
    throughput = []
    latency_avg = []
    latency_p90 = []
    if series:
        pooled = {}  # sec -> list of raw latencies across all agents
        for s in series.values():
            for sec, vals in s["buckets_ms"].items():
                pooled.setdefault(sec, []).extend(vals)
        secs = sorted(pooled)
        agg_rate = [(sec, len(pooled[sec])) for sec in secs]
        agg_avg = [(sec, sum(pooled[sec]) / len(pooled[sec])) for sec in secs]
        agg_p90 = []
        for sec in secs:
            vals = sorted(pooled[sec])
            agg_p90.append((sec, vals[min(len(vals) - 1, int(math.ceil(0.9 * len(vals))) - 1)]))
        throughput = [("total req/s", "#2563eb", moving_average(agg_rate, 5))]
        latency_avg = [("platform avg", "#2563eb", moving_average(agg_avg, 5))]
        latency_p90 = [("platform p90", "#d97706", moving_average(agg_p90, 5))]
    else:
        # No per-request streams: still chart throughput from the k6 progress
        # lines (cumulative iterations, differentiated per agent and summed).
        per_agent_cum = {}
        for log in sorted(run_dir.glob("agent-*.log")):
            cum = parse_k6_progress_lines(log)
            if len(cum) > 10:
                per_agent_cum[log.stem] = cum
        if per_agent_cum:
            maxsec = int(max(sec for pts in per_agent_cum.values() for sec, _ in pts))
            rate = []
            for sec in range(1, maxsec + 1):
                total = 0
                for pts in per_agent_cum.values():
                    d = dict(pts)
                    total += d.get(sec, d.get(sec - 1, 0)) - d.get(sec - 1, d.get(sec, 0))
                rate.append((sec, max(0, total)))
            throughput = [("total req/s", "#2563eb", moving_average(rate, 5))]
            latency_avg = latency_p90 = None
        else:
            throughput = latency_avg = latency_p90 = None

    cpu_charts = None
    cpu_series = []
    node_cpu_series = []
    if t0 is not None and engine_series:
        for i, (pod, pts) in enumerate(sorted(engine_series.items())):
            # pf-pingfederate-engine-<rs-hash>-<suffix> -> engine-<suffix>
            short = pod.split("-")[-1]
            secs = to_seconds([(r[0], r[1]) for r in pts], t0)
            cpu_series.append((f"engine-{short}", PALETTE[i % len(PALETTE)], secs))
        # Node-level CPU (percentage) for the nodes hosting the engines —
        # exposes co-tenant load that inflates per-pod CPU and latency.
        for node, pts in sorted(node_series.items()):
            secs = to_seconds([(r[0], r[2]) for r in pts], t0)  # col3 = cpu %
            if secs:
                node_cpu_series.append((node, secs))

    # ---- aggregate numbers ----
    total_reqs = sum(int(s.get("reqs", [0])[0]) for s in summaries) or \
        sum(s["total_requests"] for s in series.values())
    success_vals = [s.get("success", [100, 0, 0])[0] for s in summaries]
    success_pct = min(success_vals) if success_vals else 100.0

    # Platform-wide p95: the true pooled percentile over every measured-phase
    # datapoint across all agents (exactly the same values a reviewer would
    # recompute from the raw NDJSON streams). Falls back to the worst agent's
    # end-of-run p95 only when no streams exist.
    platform_p95 = pooled_percentile(series) if series else (
        max((s["latency"][5] for s in summaries if "latency" in s), default=0))
    duration_s = max((s["dur_p90_s"][-1][0] for s in series.values()), default=300)
    throughput_total = total_reqs / duration_s if duration_s else 0
    # Dropped iterations and achieved-vs-target rate: the generator must not
    # shed load silently (Little's-law VU cap). The end-of-run aggregate
    # includes warmup; the measured-window target is target_rate x agents x
    # measured seconds, and the measured requests exclude the warmup scenario.
    total_dropped = sum(int(s.get("dropped", [0])[0]) for s in summaries)

    def parse_duration(text):
        m = re.match(r"([\d.]+)([sm])", text)
        if not m:
            return None
        return float(m.group(1)) * (60 if m.group(2) == "m" else 1)

    warmup_configured_s = next(
        (parse_duration(s["warmup_cfg"][0]) for s in summaries if "warmup_cfg" in s), None)
    target_rate = next((float(s["target_rate"][0]) for s in summaries if "target_rate" in s), None)
    achieved_pct = None
    if target_rate and series:
        # Prefer per-request stream totals (they exclude warmup because the
        # parser filters phase=warmup points). But streams may be partial
        # (snapshot capture), so cross-check against the end-of-run total
        # minus the configured warmup traffic; use the larger, complete count.
        # Pre-warmup runs have no warmup_cfg: nothing to subtract.
        stream_reqs = sum(s["total_requests"] for s in series.values())
        if warmup_configured_s:
            log_reqs_excl_warmup = total_reqs - int(target_rate * len(summaries) * warmup_configured_s)
        else:
            log_reqs_excl_warmup = total_reqs
        measured_reqs = max(stream_reqs, log_reqs_excl_warmup)
        target_measured = target_rate * len(summaries) * duration_s
        if target_measured > 0:
            achieved_pct = 100.0 * measured_reqs / target_measured
    # Thresholds ride with the run's captured metadata (env.json), falling
    # back to the last-resort defaults; never a hardcoded constant.
    p95_gate = float(env_meta.get("P95_MS", 500.0))
    success_gate = float(env_meta.get("SUCCESS_RATE", 0.99)) * 100.0
    verdict = "PASS" if (
        platform_p95 < p95_gate
        and success_pct >= success_gate
        and (achieved_pct is None or achieved_pct >= 98)
        and total_dropped == 0
    ) else "FAIL"

    agent_rows = []
    for s in sorted(summaries, key=lambda x: x["agent"]):
        l = s["latency"]
        agent_rows.append(
            f"<tr><td>{escape(s['agent'])}</td>"
            f"<td class='num'>{l[0]:.1f}</td><td class='num'>{l[2]:.1f}</td>"
            f"<td class='num'>{l[5]:.1f}</td><td class='num'>{l[4]:.1f}</td>"
            f"<td class='num'>{l[3]:.0f}</td>"
            f"<td class='num'>{s.get('success', [0])[0]:.2f}%</td>"
            f"<td class='num'>{int(s.get('reqs', [0])[0])}</td>"
            f"<td class='num'>{int(s.get('dropped', [0])[0])}</td></tr>"
        )

    detail_sections = ""
    for agent in sorted(set(list(series.keys()) + [s["agent"] for s in summaries])):
        s = series.get(agent)
        summ = next((x for x in summaries if x["agent"] == agent), None)
        charts = ""
        if s:
            p90_max = max((v for _, v in s["dur_p90_s"]), default=0)
            charts += line_chart(f"{agent} — response time", [
                ("avg", "#2563eb", s["dur_avg_s"]),
                ("p90", "#d97706", s["dur_p90_s"]),
            ], "ms", y_max=p90_max * 1.3 or None)
            charts += line_chart(f"{agent} — throughput", [
                ("req/s (5s smooth)", "#059669", moving_average(s["req_rate"], 5)),
            ], "req/s")
        if summ and "latency" in summ:
            l = summ["latency"]
            stat_rows = (
                f"<tr><td>avg</td><td class='num'>{l[0]:.2f} ms</td></tr>"
                f"<tr><td>median</td><td class='num'>{l[2]:.2f} ms</td></tr>"
                f"<tr><td>p90</td><td class='num'>{l[4]:.2f} ms</td></tr>"
                f"<tr><td>p95</td><td class='num'>{l[5]:.2f} ms</td></tr>"
                f"<tr><td>max</td><td class='num'>{l[3]:.2f} ms</td></tr>"
                f"<tr><td>requests</td><td class='num'>{int(summ.get('reqs', [0])[0])}</td></tr>"
                f"<tr><td>success</td><td class='num'>{summ.get('success', [0])[0]:.2f}%</td></tr>"
            )
        else:
            stat_rows = "<tr><td colspan='2' class='muted'>No end-of-run summary.</td></tr>"
        detail_sections += f"""
<section id="{escape(agent)}">
  <h3>{escape(agent)}</h3>
  {charts}
  <table><tr><th>metric</th><th class="num">value</th></tr>{stat_rows}</table>
</section>"""

    # page-1 charts (skip empty)
    chart_html = ""
    if throughput:
        chart_html += line_chart("Throughput over time", throughput, "req/s",
                                 x_grid_every=30, area_fill=True)
    if latency_avg:
        chart_html += line_chart("Response time — avg", latency_avg, "ms (5s smoothing)")
        chart_html += line_chart("Response time — p90", latency_p90, "ms (5s smoothing)")
    if cpu_series:
        chart_html += stacked_area_chart("Engine CPU", cpu_series, "millicores")
    if node_cpu_series:
        # Each node's total CPU as % of its allocatable — reveals co-tenant
        # load that inflates engine CPU and latency.
        node_lines = [
            (f"node {n.split('.')[0][-11:]}", PALETTE[(i + 2) % len(PALETTE)], pts)
            for i, (n, pts) in enumerate(node_cpu_series)
        ]
        chart_html += line_chart("Hosting nodes — total CPU", node_lines,
                                 "% of node allocatable", y_max=130)
    if series:
        # Latency breakdown (M4): where the wall-clock time went — connection
        # setup, TLS, server wait, transfer. Pooled per-second means across
        # agents; explains WHAT changed when a stage's p95 moves.
        sub_means = pooled_subtiming_means(series)
        breakdown = []
        labels = {
            "http_req_connecting": ("connecting", "#d97706"),
            "http_req_tls_handshaking": ("tls_handshaking", "#7c3aed"),
            "http_req_waiting": ("waiting (server)", "#2563eb"),
            "http_req_sending": ("sending", "#059669"),
            "http_req_receiving": ("receiving", "#dc2626"),
        }
        for name, (label, color) in labels.items():
            if name in sub_means and sub_means[name]:
                breakdown.append((label, color, moving_average(sub_means[name], 5)))
        if breakdown:
            chart_html += line_chart("Latency breakdown (5s smoothing)",
                                     breakdown, "ms per phase")

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pf-perf run {escape(sys.argv[1])}</title>
<style>
  :root {{
    color-scheme: light dark;
    --fg: #0f172a; --fg-soft: #475569; --bg: #f1f5f9; --card: #ffffff;
    --line: #e2e8f0; --muted: #64748b; --accent: #2563eb;
    --green: #059669; --red: #dc2626; --amber-bg: #fffbeb; --amber-line: #f59e0b;
    --amber-fg: #92400e; --shadow: 0 1px 3px rgba(15,23,42,.06), 0 1px 2px rgba(15,23,42,.04);
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --fg: #e2e8f0; --fg-soft: #94a3b8; --bg: #0b0f17; --card: #131a26;
      --line: #253044; --muted: #7c8aa0; --accent: #3b82f6;
      --green: #34d399; --red: #f87171; --amber-bg: #3d2f10; --amber-line: #b45309;
      --amber-fg: #fbbf24;
      --shadow: 0 1px 3px rgba(0,0,0,.4);
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font: 14px/1.55 -apple-system, "Segoe UI", Inter, sans-serif; margin: 0 auto;
    padding: 0 20px 40px; max-width: 960px; background: var(--bg); color: var(--fg);
  }}
  header.hero {{
    padding: 26px 0 14px; display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap;
  }}
  header.hero h1 {{ font-size: 21px; font-weight: 700; letter-spacing: -.01em; margin: 0; }}
  header.hero .rid {{ font-family: ui-monospace, monospace; font-size: 12px; color: var(--muted);
    background: var(--card); border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px; }}
  nav.pages {{
    position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 88%, transparent);
    backdrop-filter: blur(6px); padding: 8px 0; margin-bottom: 6px;
    border-bottom: 1px solid var(--line);
  }}
  nav.pages a {{
    color: var(--fg-soft); text-decoration: none; font-size: 13px; font-weight: 500;
    padding: 5px 12px; border-radius: 999px; margin-right: 6px;
  }}
  nav.pages a:hover {{ background: var(--card); color: var(--fg); }}
  h2 {{ font-size: 16px; font-weight: 650; margin: 26px 0 10px; letter-spacing: -.01em; }}
  h3 {{ font-size: 14px; margin: 18px 0 6px; }}
  .tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 10px; margin: 12px 0 4px; }}
  .tile {{
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    padding: 12px 16px; box-shadow: var(--shadow);
  }}
  .tile .v {{ font-size: 22px; font-weight: 700; font-variant-numeric: tabular-nums;
              letter-spacing: -.01em; }}
  .tile .l {{ font-size: 10px; color: var(--muted); text-transform: uppercase;
              letter-spacing: .06em; margin-top: 1px; }}
  .pass {{ color: var(--green); }} .fail {{ color: var(--red); }}
  table {{ border-collapse: separate; border-spacing: 0; width: 100%; margin: 10px 0;
           background: var(--card); border: 1px solid var(--line); border-radius: 12px;
           overflow: hidden; box-shadow: var(--shadow); }}
  th, td {{ text-align: left; padding: 7px 14px; border-bottom: 1px solid var(--line);
            font-variant-numeric: tabular-nums; }}
  tr:last-child td {{ border-bottom: none; }}
  th {{ font-size: 10px; text-transform: uppercase; color: var(--muted);
        letter-spacing: .06em; background: color-mix(in srgb, var(--card) 92%, var(--bg)); }}
  .num {{ text-align: right; }}
  figure.chart {{
    margin: 12px 0; background: var(--card); border: 1px solid var(--line);
    border-radius: 12px; padding: 12px 14px 8px; box-shadow: var(--shadow);
  }}
  figcaption {{ font-size: 13px; font-weight: 600; margin-bottom: 4px; }}
  .unit {{ font-weight: 400; color: var(--muted); font-size: 11px; margin-left: 6px; }}
  svg.svg {{ width: 100%; height: auto; display: block; }}
  .tick {{ font-size: 9px; fill: var(--muted); }}
  .legend {{ margin-top: 4px; font-size: 11px; color: var(--muted); }}
  .lg i {{ display: inline-block; width: 9px; height: 9px; border-radius: 2px;
           margin: 0 5px 0 12px; }}
  .lg:first-child i {{ margin-left: 0; }}
  .muted {{ color: var(--muted); }}
  .warn {{
    background: var(--amber-bg); border: 1px solid var(--amber-line); color: var(--amber-fg);
    padding: 9px 13px; border-radius: 10px; font-size: 12px; margin: 10px 0;
  }}
  footer {{ margin-top: 34px; font-size: 10px; color: var(--muted); }}
</style></head><body>
<header class="hero">
  <h1>Token-exchange performance</h1>
  <span class="rid">run {escape(sys.argv[1])}</span>
</header>
<nav class="pages">
  <a href="#aggregated">Aggregated</a>
  <a href="#agents">Per-agent details</a>
</nav>
<h2 id="aggregated">Aggregated</h2>
<div class="tiles">
  <div class="tile"><div class="v {verdict.lower()}">{verdict}</div><div class="l">thresholds</div></div>
  <div class="tile"><div class="v">{success_pct:.2f}%</div><div class="l">min success</div></div>
  <div class="tile"><div class="v">{platform_p95:.1f} ms</div><div class="l">platform p95</div></div>
  <div class="tile"><div class="v">{'—' if achieved_pct is None else f'{achieved_pct:.1f}%'}</div><div class="l">achieved vs target rate</div></div>
  <div class="tile"><div class="v {verdict.lower() if total_dropped else ''}">{total_dropped:,}</div><div class="l">dropped iterations</div></div>
  <div class="tile"><div class="v">{throughput_total:.0f}/s</div><div class="l">avg throughput</div></div>
  <div class="tile"><div class="v">{total_reqs:,}</div><div class="l">total requests</div></div>
</div>
{'<p class="warn">Note: time-series request counts do not match the end-of-run summaries — the series may be synthetic/preview data.</p>' if fixture_warning else ''}{'<p class="muted">Note: per-request streams are snapshotted while the agents run; the last few seconds of each stream are missing (end-of-run summaries are complete).</p>' if stream_truncated else ''}
{chart_html}
<h2 id="agents">Per-agent details</h2>
<p class="muted">{len(summaries)} agent(s) in this run.</p>
<table><tr><th>agent</th><th class="num">avg ms</th><th class="num">med ms</th>
<th class="num">p95 ms</th><th class="num">p90 ms</th><th class="num">max ms</th>
<th class="num">success</th><th class="num">requests</th><th class="num">dropped</th></tr>
{''.join(agent_rows)}
</table>
{detail_sections}
<footer>Generated {timestamp} by scripts/generate-report.py — self-contained, no external resources.</footer>
</body></html>"""
    out = run_dir / "report.html"
    out.write_text(html)
    print(f"Report written: {out}")

    # Commit-friendly per-run summary (raw streams stay out of git; this
    # JSON makes the evidence behind any report claim version-controlled).
    summary = {
        "run_id": sys.argv[1],
        "profile": env_meta.get("profile"),
        "timestamp_utc": timestamp,
        "verdict": verdict,
        "p95_pooled_measured_ms": round(platform_p95, 2),
        "p95_gate_ms": p95_gate,
        "success_pct": round(success_pct, 2),
        "achieved_vs_target_pct": round(achieved_pct, 2) if achieved_pct is not None else None,
        "target_rate_per_agent": target_rate,
        "dropped_iterations": total_dropped,
        "total_requests_measured": sum(s["total_requests"] for s in series.values()) if series else total_reqs,
        "measured_duration_s": duration_s,
        "agents": [
            {
                "agent": s["agent"],
                "avg_ms": s["latency"][0],
                "p95_ms": s["latency"][5],
                "success_pct": s.get("success", [0])[0],
                "requests": int(s.get("reqs", [0])[0]),
                "dropped": int(s.get("dropped", [0])[0]),
            }
            for s in sorted(summaries, key=lambda x: x["agent"])
        ],
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    print(f"Summary written: {run_dir / 'summary.json'}")


if __name__ == "__main__":
    main()
