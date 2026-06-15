"""backup9 status API. Reads /var/lib/backup9/state/<job>.json files written
by backup-run and exposes them at :8094. JARVIS/Apollo poll this."""
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, Response

STATE_DIR = Path("/var/lib/backup9/state")
JOBS_YAML = Path("/etc/backup9/jobs.yaml")

app = FastAPI(title="backup9-status")

_FAVICON = (
    b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    b'<text y="50" font-size="56">\xf0\x9f\x97\x84\xef\xb8\x8f</text></svg>'
)


@app.get("/favicon.ico")
def favicon():
    return Response(_FAVICON, media_type="image/svg+xml")


def jobs_list() -> list[dict]:
    return yaml.safe_load(JOBS_YAML.read_text())["jobs"] if JOBS_YAML.exists() else []


def read_state(name: str) -> dict | None:
    f = STATE_DIR / f"{name}.json"
    if not f.exists():
        return None
    try:
        return json.loads(f.read_text())
    except json.JSONDecodeError:
        return None


# Cache live `zfs list` output for 15 s so the dashboard doesn't fork a
# subprocess per request. The numbers move slowly (post-rsync + post-
# snapshot), so a 15 s TTL is plenty fresh for the UI.
_ZFS_CACHE_TTL = 15
_zfs_cache: dict[str, tuple[float, dict[str, dict[str, int]]]] = {}


def zfs_live_sizes() -> dict[str, dict[str, int]]:
    """{dataset: {'used': bytes, 'referenced': bytes}} from one `zfs list`
    sweep. Used to back-fill old state JSONs that lack the size fields
    (state pre-dates backup-run carrying them, 2026-06-15)."""
    now = time.time()
    if _zfs_cache.get("v") and now - _zfs_cache["v"][0] < _ZFS_CACHE_TTL:
        return _zfs_cache["v"][1]
    out: dict[str, dict[str, int]] = {}
    try:
        r = subprocess.run(
            ["zfs", "list", "-H", "-p", "-r",
             "-o", "name,used,referenced", "backup/freja"],
            capture_output=True, text=True, check=True, timeout=8,
        )
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            name, used, ref = parts[0], parts[1], parts[2]
            try:
                out[name] = {"used": int(used), "referenced": int(ref)}
            except ValueError:
                continue
    except Exception:
        pass
    _zfs_cache["v"] = (now, out)
    return out


def age_hours(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - t).total_seconds() / 3600
    except ValueError:
        return None


def fmt_bytes(n: int | None) -> str:
    """Human-readable size for the dashboard. Base-1024 since we're
    showing disk usage, not transfer rates."""
    if n is None:
        return "&mdash;"
    f = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or u == "TB":
            return f"{f:.1f} {u}"
        f /= 1024
    return f"{f:.1f} TB"


@app.get("/health")
def health():
    return {"ok": True, "jobs": len(jobs_list())}


@app.get("/", response_class=HTMLResponse)
def index():
    rows = []
    zfs_live = zfs_live_sizes()
    for j in jobs_list():
        st = read_state(j["name"]) or {}
        # Live ZFS fallback for target sizes when the state JSON pre-dates
        # the source/target instrumentation. Doesn't help source_bytes
        # (only rsync --stats knows it).
        live = zfs_live.get((j.get("zfs_dataset") or "").strip())
        if live:
            st.setdefault("target_bytes", live["used"])
            st.setdefault("target_referenced_bytes", live["referenced"])
        status = st.get("status") or "no-run"
        ah = age_hours(st.get("finished"))
        dur = st.get("duration_s")
        snap = st.get("snapshot") or ""
        err = st.get("error") or ""

        # Apollo accessibility: text-label + glyph + colour, never colour-only.
        if status == "ok":
            glyph, css, label = "✓", "ok",   "UP"
        elif status == "failed":
            glyph, css, label = "✕", "fail", "DOWN"
        elif status == "running":
            glyph, css, label = "▶", "warn", "RUNNING"
        else:
            glyph, css, label = "○", "idle", "NEVER RUN"

        if ah is None:
            age_str = "&mdash;"
        elif ah < 1:
            age_str = f"{int(ah * 60)} min"
        elif ah < 48:
            age_str = f"{ah:.1f} h"
        else:
            age_str = f"{ah/24:.1f} d"

        dur_str = f"{dur:.1f} s" if dur and dur < 60 else \
                  f"{dur/60:.1f} min" if dur else "&mdash;"

        src_size = fmt_bytes(st.get("source_bytes"))
        tgt_size = fmt_bytes(st.get("target_bytes"))
        tgt_ref = st.get("target_referenced_bytes")
        tgt_tooltip = (f"used={fmt_bytes(st.get('target_bytes'))} "
                       f"(live={fmt_bytes(tgt_ref)}, snapshots="
                       f"{fmt_bytes((st.get('target_bytes') or 0) - (tgt_ref or 0)) if tgt_ref is not None else '?'})"
                       if st.get("target_bytes") is not None else "")

        rows.append(f"""
        <tr class="{css}">
          <td class="name">{j['name']}</td>
          <td><span class="badge {css}">{glyph} {label}</span></td>
          <td>{age_str}</td>
          <td>{dur_str}</td>
          <td class="num">{src_size}</td>
          <td class="num" title="{tgt_tooltip}">{tgt_size}</td>
          <td class="src">{j['source']}</td>
          <td class="snap" title="{snap}">{snap.split('@')[-1] if '@' in snap else '&mdash;'}</td>
          <td class="err">{err}</td>
        </tr>""")

    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>backup9 status</title>
<link rel="icon" href="/favicon.ico">
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://apollo.hoej.eu/static/lab-header.css">
<script src="https://apollo.hoej.eu/static/lab-header.js" defer></script>
<style>
  :root {{
    --bg:#11141a; --fg:#d8dee9; --muted:#6c7686;
    --card:#1a1f2a; --border:#2a3142; --accent:#5e9eff;
    --up:#4ade80; --warn:#fbbf24; --down:#f87171;
  }}
  body {{ margin:0; padding:0; background:var(--bg); color:var(--fg);
         font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }}
  main {{ padding: 1.4rem 1.6rem; }}
  h1 {{ margin: 0 0 0.25rem; font-size: 1.25rem; font-weight: 600; }}
  .sub {{ color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem; }}
  table {{ border-collapse: collapse; width: 100%;
           background: var(--card); border-radius: 9px; overflow: hidden;
           border: 1px solid var(--border); }}
  th, td {{ padding: 0.55rem 0.85rem; text-align: left;
            border-bottom: 1px solid var(--border); font-size: 0.88rem; }}
  th {{ background:#161a23; font-weight:600; color:var(--muted);
        font-size: 0.74rem; text-transform: uppercase; letter-spacing: 0.5px; }}
  tr:last-child td {{ border-bottom: none; }}
  td.name {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
             font-weight: 600; }}
  td.src, td.snap {{ font-family: ui-monospace, monospace; font-size: 0.78rem;
                     color: var(--muted); }}
  td.num, th.num {{ font-family: ui-monospace, monospace; text-align: right; }}
  td.err {{ color: var(--down); font-size: 0.78rem; }}
  .badge {{ display: inline-block; padding: 2px 10px; border-radius: 4px;
            font-size: 0.74rem; font-weight: 700; letter-spacing: 0.4px;
            font-family: ui-monospace, monospace;
            min-width: 78px; text-align: center; }}
  .badge.ok   {{ background:rgba(74,222,128,.14); color:var(--up);
                 border:1px solid rgba(74,222,128,.45); }}
  .badge.fail {{ background:rgba(248,113,113,.14); color:var(--down);
                 border:1px solid rgba(248,113,113,.45); }}
  .badge.warn {{ background:rgba(251,191,36,.14); color:var(--warn);
                 border:1px solid rgba(251,191,36,.45); }}
  .badge.idle {{ background:rgba(108,118,134,.14); color:var(--muted);
                 border:1px solid rgba(108,118,134,.45); }}
  tr.fail td {{ background:rgba(248,113,113,.06); }}
  tr.warn td {{ background:rgba(251,191,36,.06); }}
  footer {{ margin-top: 1rem; color: var(--muted); font-size: 0.78rem; }}
  footer a {{ color: var(--accent); text-decoration: none; }}
  footer a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>
<div id="lab-header"></div>
<main>
  <h1>backup9 status</h1>
  <div class="sub">Offsite backup &mdash; FREJA shares pulled to encrypted ZFS pool</div>
  <table>
    <thead><tr>
      <th>Job</th><th>Status</th><th>Last run</th><th>Duration</th>
      <th class="num">Source size</th><th class="num">Target size</th>
      <th>Source</th><th>Last snapshot</th><th>Error</th>
    </tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table>
  <footer>
    JSON: <a href="/api/jobs">/api/jobs</a> &middot;
    Health: <a href="/health">/health</a>
  </footer>
</main>
</body>
</html>"""
    return html


@app.get("/api/jobs")
def list_jobs():
    out = []
    zfs_live = zfs_live_sizes()
    for j in jobs_list():
        st = read_state(j["name"]) or {}
        live = zfs_live.get((j.get("zfs_dataset") or "").strip())
        if live:
            st.setdefault("target_bytes", live["used"])
            st.setdefault("target_referenced_bytes", live["referenced"])
        out.append({
            "name": j["name"],
            "source": j["source"],
            "dest": j["dest"],
            "schedule": j["schedule"],
            "last_status": st.get("status"),
            "last_run": st.get("finished"),
            "age_hours": age_hours(st.get("finished")),
            "duration_s": st.get("duration_s"),
            "source_bytes": st.get("source_bytes"),
            "target_bytes": st.get("target_bytes"),
            "target_referenced_bytes": st.get("target_referenced_bytes"),
            "snapshot": st.get("snapshot"),
            "error": st.get("error"),
        })
    return {"jobs": out}


@app.get("/api/jobs/{name}")
def get_job(name: str):
    j = next((j for j in jobs_list() if j["name"] == name), None)
    if not j:
        raise HTTPException(404, "unknown job")
    st = read_state(name) or {}
    return {"job": j, "state": st}
