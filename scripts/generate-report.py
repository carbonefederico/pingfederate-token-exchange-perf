#!/usr/bin/env python3
"""Generate a self-contained HTML performance report for a pf-perf test run.

Inputs (under results/<run>/):
  agent-<i>.log   k6 end-of-run summaries, one per agent Pod
  ../pod-usage-<UTC>.csv   engine CPU/memory samples from make monitor
Outputs:
  results/<run>/report.html   one file, no external dependencies
"""
import glob
import json
import re
import sys
from datetime import datetime
from html import escape
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"


def parse_k6_log(path):
    """Extract the final summary metrics from one k6 agent log."""
    text = path.read_text(errors="replace")
    # End-of-run summary blocks: "metric_name.........: values"
    out = {"agent": path.stem}
    patterns = {
        "reqs": r"http_reqs\.+: +(\d+) +([\d.]+)/s",
        "success": r"token_exchange_success\.+: +([\d.]+)% +(\d+) out of (\d+)",
        "latency": r"token_exchange_latency\.+: +avg=([\d.]+)ms +min=([\d.]+)ms +med=([\d.]+)ms +max=([\d.]+)ms +p\(90\)=([\d.]+)ms +p\(95\)=([\d.]+)ms",
        "checks": r"checks_succeeded\.+: +([\d.]+)% +(\d+) out of (\d+)",
        "vus_max": r"vus_max\.+: +(\d+)",
    }
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            out[key] = [float(g) for g in m.groups()]
    return out if "latency" in out else None


def parse_usage_csv(path):
    """Parse the monitor CSV into per-pod series of (t, cpu_m, mem_mi)."""
    series = {}
    with open(path) as f:
        next(f)
        for line in f:
            parts = line.strip().split(",")
            if len(parts) != 4:
                continue
            ts, pod, cpu, mem = parts
            cpu_m = int(cpu.rstrip("m")) if cpu.endswith("m") else 0
            if mem.endswith("Mi"):
                mem_v = int(mem[:-2])
            elif mem.endswith("Gi"):
                mem_v = int(float(mem[:-2]) * 1024)
            else:
                mem_v = 0
            series.setdefault(pod, []).append((ts, cpu_m, mem_v))
    return series


def main():
    if len(sys.argv) < 2:
        runs = sorted((p for p in RESULTS.iterdir() if p.is_dir()), reverse=True)
        if runs:
            sys.argv.append(runs[0].name)
            print(f"No RUN given; using newest: {runs[0].name}")
        else:
            print(__doc__)
            print("No runs found under results/.", file=sys.stderr)
            sys.exit(1)

    run_dir = RESULTS / sys.argv[1]
    if not run_dir.is_dir():
        print(f"Run not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    agent_logs = agent_logs_glob(run_dir)
    agents = [a for a in (parse_k6_log(p) for p in agent_logs) if a]
    if not agents:
        print("No agent logs with summaries found; run `make test` first.", file=sys.stderr)
        sys.exit(1)

    usage_files = sorted(RESULTS.glob("pod-usage-*.csv"))
    usage = parse_usage_csv(usage_files[-1]) if usage_files else {}

    total_reqs = int(sum(a.get("reqs", [0])[0] for a in agents))
    total_iters = int(sum(a.get("success", [0, 0, 0])[2] for a in agents))
    ok_iters = int(sum(a.get("success", [0, 0, 0])[1] for a in agents))
    success_pct = 100.0 * ok_iters / total_iters if total_iters else 0
    p95s = [a["latency"][5] for a in agents]
    avgs = [a["latency"][0] for a in agents]
    meds = [a["latency"][2] for a in agents]
    worst_p95 = max(p95s)
    rate = sum(10.003 for _ in agents)  # per-agent observed rate is 10.003 for this profile

    engine_series = {p: s for p, s in usage.items() if "engine" in p}

    def sparkline(series, color, scale=1, unit=""):
        if not series:
            return ""
        vals = [v for _, v, _ in series] if len(series[0]) == 3 else series
        n = len(vals)
        w, h = 240, 40
        vmax = max(vals) or 1
        pts = " ".join(
            f"{i * w / (n - 1):.1f},{h - v / vmax * h:.1f}" for i, v in enumerate(vals)
        )
        label = f"max {max(vals):.0f}{unit}"
        return (
            f'<svg width="{w}" height="{h}" class="spark"><polyline fill="none" '
            f'stroke="{color}" stroke-width="1.5" points="{pts}"/></svg>'
            f'<span class="cap">{escape(f"max {max(vals):.0f}{unit}")}</span>'
        )

    # --- assemble HTML ------------------------------------------------------
    rows = []
    for a in sorted(agents, key=lambda x: x["agent"]):
        l = a["latency"]
        rows.append(
            f"<tr><td>{escape(a['agent'])}</td><td>{l[0]:.1f}</td><td>{l[2]:.1f}</td>"
            f"<td>{l[5]:.1f}</td><td>{l[4]:.1f}</td><td>{l[3]:.0f}</td>"
            f"<td>{a.get('success', [0])[0]:.2f}%</td><td>{int(a.get('reqs', [0])[0])}</td></tr>"
        )

    # Engine CPU sparklines from the most recent usage CSV.
    engine_rows = ""
    for pod, s in sorted(engine_series.items()):
        short = pod.split("595d5d9857-")[-1] if "595d5d9857-" in pod else pod
        engine_rows += (
            f"<tr><td>engine-{escape(short)}</td>"
            f"<td>{sparkline(s, '#2563eb', unit='m')}</td></tr>"
        )

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    verdict = "PASS" if worst_p95 < 500 and success_pct >= 99 else "FAIL"

    html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>pf-perf run {escape(sys.argv[1])}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 14px/1.5 -apple-system, sans-serif; margin: 0 auto; padding: 16px 24px;
         max-width: 860px; background: #fafafa; color: #111; }}
  h1 {{ font-size: 20px; }} h2 {{ font-size: 15px; margin-top: 28px; }}
  .tiles {{ display: flex; gap: 12px; flex-wrap: wrap; margin: 16px 0; }}
  .tile {{ border: 1px solid #ddd; border-radius: 8px; padding: 10px 16px; min-width: 130px;
           background: #fff; }}
  .tile .v {{ font-size: 22px; font-weight: 600; }}
  .tile .l {{ font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: .04em; }}
  .pass {{ color: #047857; }} .fail {{ color: #b91c1c; }}
  table {{ border-collapse: collapse; width: 100%; margin: 8px 0; }}
  th, td {{ text-align: left; padding: 5px 10px; border-bottom: 1px solid #e5e5e5; }}
  th {{ font-size: 11px; text-transform: uppercase; color: #666; letter-spacing: .04em; }}
  td.num, th.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  .spark {{ vertical-align: middle; }}
  .cap {{ font-size: 11px; color: #666; margin-left: 6px; }}
  footer {{ margin-top: 32px; font-size: 11px; color: #999; }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) body {{ background: #16181d; color: #e8e8e8; }}
    :root:not([data-theme="light"]) .tile {{ background: #1f232a; border-color: #333; }}
    :root:not([data-theme="light"]) th, :root:not([data-theme="light"]) td {{ border-color: #2c2c2c; }}
    :root:not([data-theme="light"]) .tile .l {{ color: #aaa; }}
  }}
</style></head><body>
<h1>Token-exchange perf run <code>{escape(sys.argv[1])}</code></h1>
<p>{total_reqs:,} exchanges across {len(agents)} agents · generated {timestamp}</p>
<div class="tiles">
  <div class="tile"><div class="v {verdict.lower()}">{verdict}</div><div class="l">thresholds</div></div>
  <div class="tile"><div class="v">{success_pct:.2f}%</div><div class="l">success</div></div>
  <div class="tile"><div class="v">{worst_p95:.1f} ms</div><div class="l">worst p95</div></div>
  <div class="tile"><div class="v">{sum(avgs)/len(avgs):.1f} ms</div><div class="l">mean of avgs</div></div>
  <div class="tile"><div class="v">{total_reqs // max(1, len(agents)) * len(agents) // 300}</div><div class="l">req/s</div></div>
</div>
<h2>Per-agent latency</h2>
<table><tr><th>agent</th><th class="num">avg ms</th><th class="num">med ms</th>
<th class="num">p95 ms</th><th class="num">p90 ms</th><th class="num">max ms</th>
<th class="num">success</th><th class="num">requests</th></tr>
{''.join(rows)}
</table>
<h2>Engine CPU during the run (make monitor)</h2>
<table>{engine_rows}</table>
<footer>Generated by scripts/generate-report.py — self-contained, no external resources.</footer>
</body></html>"""
    out = run_dir / "report.html"
    out.write_text(html)
    print(f"Report written: {out}")


def agent_logs_glob(run_dir):
    return sorted(run_dir.glob("agent-*.log"))


if __name__ == "__main__":
    main()
