"""backup9 status API. Reads /var/lib/backup9/state/<job>.json files written
by backup-run and exposes them at :8094. JARVIS/Apollo poll this."""
import json
from datetime import datetime, timezone
from pathlib import Path

import yaml
from fastapi import FastAPI, HTTPException

STATE_DIR = Path("/var/lib/backup9/state")
JOBS_YAML = Path("/etc/backup9/jobs.yaml")

app = FastAPI(title="backup9-status")


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
