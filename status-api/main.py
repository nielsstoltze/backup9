"""backup9 status API. Reads /var/lib/backup9/state/<job>.json files written
by backup-run and exposes them at :8094. JARVIS/Apollo poll this."""
import json
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


def age_hours(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - t).total_seconds() / 3600
    except ValueError:
        return None


@app.get("/health")
def health():
    return {"ok": True, "jobs": len(jobs_list())}


@app.get("/", response_class=HTMLResponse)
def index():
    rows = []
    for j in jobs_list():
        st = read_state(j["name"]) or {}
        status = st.get("status") or "no-run"
        ah = age_hours(st.get("finished"))
        dur = st.get("duration_s")
        snap = st.get("snapshot") or ""
        err = st.get("error") or ""

        if status == "ok":
            glyph, css, label = "OK", "ok", "OK"
        elif status == "failed":
            glyph, css, label = "FAIL", "fail", "FAIL"
        elif status == "running":
            glyph, css, label = "RUN", "warn", "RUNNING"
        else:
            glyph, css, label = "--", "idle", "NEVER RUN"

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

        rows.append(f"""
        <tr class="{css}">
          <td class="name">{j['name']}</td>
          <td><span class="badge {css}">{glyph}</span> {label}</td>
          <td>{age_str}</td>
          <td>{dur_str}</td>
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
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         margin: 0; padding: 1.5rem; background: #f6f7f9; color: #222; }}
  h1 {{ margin: 0 0 0.25rem; font-size: 1.3rem; }}
  .sub {{ color: #666; font-size: 0.85rem; margin-bottom: 1rem; }}
  table {{ border-collapse: collapse; width: 100%; background: white;
           box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  th, td {{ padding: 0.55rem 0.85rem; text-align: left;
            border-bottom: 1px solid #eee; font-size: 0.9rem; }}
  th {{ background: #f0f1f4; font-weight: 600; font-size: 0.78rem;
        text-transform: uppercase; letter-spacing: 0.5px; color: #555; }}
  td.name {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
             font-weight: 600; }}
  td.src, td.snap {{ font-family: ui-monospace, monospace; font-size: 0.82rem;
                     color: #666; }}
  td.err {{ color: #b00; font-size: 0.8rem; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 3px;
            font-size: 0.72rem; font-weight: 700; letter-spacing: 0.5px;
            color: white; min-width: 38px; text-align: center; }}
  .badge.ok   {{ background: #1c8a3f; }}
  .badge.fail {{ background: #c0392b; }}
  .badge.warn {{ background: #d68910; }}
  .badge.idle {{ background: #888; }}
  tr.fail td {{ background: #fff5f4; }}
  tr.warn td {{ background: #fffbef; }}
  footer {{ margin-top: 1rem; color: #888; font-size: 0.78rem; }}
  footer a {{ color: #666; }}
</style>
</head>
<body>
  <h1>backup9 status</h1>
  <div class="sub">Offsite backup &mdash; FREJA shares pulled to encrypted ZFS pool</div>
  <table>
    <thead><tr>
      <th>Job</th><th>Status</th><th>Last run</th><th>Duration</th>
      <th>Source</th><th>Last snapshot</th><th>Error</th>
    </tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table>
  <footer>
    JSON: <a href="/api/jobs">/api/jobs</a> &middot;
    Health: <a href="/health">/health</a>
  </footer>
</body>
</html>"""
    return html


@app.get("/api/jobs")
def list_jobs():
    out = []
    for j in jobs_list():
        st = read_state(j["name"]) or {}
        out.append({
            "name": j["name"],
            "source": j["source"],
            "dest": j["dest"],
            "schedule": j["schedule"],
            "last_status": st.get("status"),
            "last_run": st.get("finished"),
            "age_hours": age_hours(st.get("finished")),
            "duration_s": st.get("duration_s"),
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
