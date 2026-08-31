"""
TradingAgents API
-----------------
Endpoints:
  GET  /                      — the static viewer SPA (was nginx's job;
                                 see the "Static viewer" section below for why
                                 it moved here when Caddy replaced nginx)
  GET  /api/reports          — list all report folders with metadata
  GET  /api/reports/{folder}/{path:path}  — serve a single .md file
  POST /api/run              — start an analysis (SSE stream of log lines)
  GET  /api/run/{job_id}     — re-attach to a running job's SSE stream
  GET  /api/jobs             — list active/recent jobs
"""

import asyncio
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import AsyncGenerator

import aiofiles
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

# ── Config ────────────────────────────────────────────────────────────────────
REPORTS_PATH      = Path(os.environ.get("REPORTS_PATH", "/data/reports"))
TRADINGAGENTS_DIR = Path(os.environ.get("TRADINGAGENTS_PATH", "/app/TradingAgents"))
VIEWER_HTML        = Path(os.environ.get("VIEWER_HTML", "/app/viewer/index.html"))

# Subfolder → file keys mapping (mirrors TradingAgents output structure)
REPORT_STRUCTURE = {
    "1_analysts":  ["fundamentals", "market", "news", "sentiment"],
    "2_research":  ["bull", "bear", "manager"],
    "3_trading":   ["trader"],
    "4_risk":      ["aggressive", "neutral", "conservative"],
    "5_portfolio": ["decision"],
}
ALL_KEYS = [k for keys in REPORT_STRUCTURE.values() for k in keys]

# In-memory job store  {job_id: {"status", "ticker", "date", "lines": [], "proc"}}
JOBS: dict[str, dict] = {}

app = FastAPI(title="TradingAgents API", root_path="/api")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def parse_folder_name(name: str) -> dict:
    """Extract ticker / date / time from TICKER_YYYYMMDD_HHMMSS folder names."""
    m = re.match(r"^([A-Z0-9.\-\^]+)_(\d{4})(\d{2})(\d{2})_(\d{6})$", name, re.I)
    if m:
        return {
            "ticker": m.group(1).upper(),
            "date":   f"{m.group(2)}-{m.group(3)}-{m.group(4)}",
            "time":   f"{m.group(5)[:2]}:{m.group(5)[2:4]}:{m.group(5)[4:]}",
        }
    return {"ticker": None, "date": None, "time": None}


def extract_verdict(decision_text: str) -> str:
    m = re.search(r"\*\*Rating\*\*:\s*(\w+)", decision_text, re.I)
    if not m:
        m = re.search(r"\*\*(Buy|Sell|Hold)\*\*", decision_text, re.I)
    return m.group(1).upper() if m else ""


def extract_excerpt(decision_text: str, length: int = 200) -> str:
    m = re.search(
        r"\*\*Executive Summary\*\*:\s*([\s\S]+?)(?=\*\*Investment Thesis|\*\*Price|$)",
        decision_text, re.I,
    )
    text = m.group(1).strip() if m else decision_text.replace("**", "")
    return text[:length].rstrip() + ("…" if len(text) > length else "")


async def read_file_safe(path: Path) -> str | None:
    try:
        async with aiofiles.open(path, "r", encoding="utf-8", errors="replace") as f:
            return await f.read()
    except Exception:
        return None


async def load_report_files(folder_path: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for subdir, keys in REPORT_STRUCTURE.items():
        sub = folder_path / subdir
        for key in keys:
            text = await read_file_safe(sub / f"{key}.md")
            if text is not None:
                files[key] = text
    complete = await read_file_safe(folder_path / "complete_report.md")
    if complete:
        files["complete_report"] = complete
    return files


# ── Routes ────────────────────────────────────────────────────────────────────

# Static viewer — previously nginx's job (serving /var/www/html directly).
# Caddy replaced nginx as the edge proxy and, per the docker-compose.prod.yml
# design, only ever reverse-proxies to this service rather than also running
# its own file_server — so the app itself needs to serve its one HTML file.
# (The viewer is a single self-contained file — see viewer/README or its
# <script src> for the one external dependency, marked.js off a CDN — so a
# single FileResponse is enough; this isn't a multi-asset SPA needing a
# StaticFiles mount.)
@app.get("/")
async def serve_viewer():
    if not VIEWER_HTML.exists():
        raise HTTPException(status_code=500, detail=f"Viewer HTML not found at {VIEWER_HTML}")
    return FileResponse(VIEWER_HTML)


@app.get("/reports")
async def list_reports():
    """Return metadata for all report folders, newest first."""
    if not REPORTS_PATH.exists():
        return []

    results = []
    for entry in sorted(REPORTS_PATH.iterdir(), reverse=True):
        if not entry.is_dir():
            continue
        meta = parse_folder_name(entry.name)

        # Quick peek at decision.md for verdict + excerpt
        decision_path = entry / "5_portfolio" / "decision.md"
        decision_text = await read_file_safe(decision_path) or ""
        verdict = extract_verdict(decision_text)
        excerpt = extract_excerpt(decision_text)

        # Count how many expected files are present
        present = sum(
            1 for sd, keys in REPORT_STRUCTURE.items()
            for k in keys
            if (entry / sd / f"{k}.md").exists()
        )
        total = sum(len(v) for v in REPORT_STRUCTURE.values())

        results.append({
            "folder":  entry.name,
            "ticker":  meta["ticker"],
            "date":    meta["date"],
            "time":    meta["time"],
            "verdict": verdict,
            "excerpt": excerpt,
            "files_present": present,
            "files_total":   total,
        })

    return results


@app.get("/reports/{folder}/{file_key}")
async def get_report_file(folder: str, file_key: str):
    """Return the markdown text for a single report file."""
    # Sanitise inputs — no path traversal
    if ".." in folder or ".." in file_key or "/" in folder:
        raise HTTPException(status_code=400, detail="Invalid path")

    folder_path = REPORTS_PATH / folder
    if not folder_path.exists():
        raise HTTPException(status_code=404, detail="Report folder not found")

    # Find the file across subfolders
    for subdir, keys in REPORT_STRUCTURE.items():
        if file_key in keys:
            path = folder_path / subdir / f"{file_key}.md"
            text = await read_file_safe(path)
            if text is not None:
                return {"folder": folder, "key": file_key, "content": text}
            raise HTTPException(status_code=404, detail=f"{file_key}.md not found")

    raise HTTPException(status_code=404, detail=f"Unknown file key: {file_key}")


@app.get("/reports/{folder}")
async def get_report(folder: str):
    """Return all files for a report folder in one request."""
    if ".." in folder or "/" in folder:
        raise HTTPException(status_code=400, detail="Invalid path")
    folder_path = REPORTS_PATH / folder
    if not folder_path.exists():
        raise HTTPException(status_code=404, detail="Report folder not found")
    files = await load_report_files(folder_path)
    meta  = parse_folder_name(folder)
    return {"folder": folder, **meta, "files": files}


# ── Analysis runner ───────────────────────────────────────────────────────────

class RunRequest(BaseModel):
    ticker: str
    date:   str          # YYYY-MM-DD
    llm_provider: str = "anthropic"
    model:        str = "claude-sonnet-5"


@app.post("/run")
async def start_run(req: RunRequest):
    """Kick off a TradingAgents analysis. Returns a job_id for SSE streaming."""
    ticker = req.ticker.upper().strip()
    if not re.match(r"^[A-Z0-9.\-\^]{1,10}$", ticker):
        raise HTTPException(status_code=400, detail="Invalid ticker symbol")
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", req.date):
        raise HTTPException(status_code=400, detail="Date must be YYYY-MM-DD")

    job_id = str(uuid.uuid4())[:8]
    JOBS[job_id] = {
        "status":   "running",
        "ticker":   ticker,
        "date":     req.date,
        "created":  time.time(),
        "lines":    [],
        "proc":     None,
        "folder":   None,
    }

    asyncio.create_task(_run_analysis(job_id, ticker, req.date, req.model))
    return {"job_id": job_id}


async def _run_analysis(job_id: str, ticker: str, date: str, model: str):
    """Run TradingAgents as a subprocess, capture output line by line."""
    job = JOBS[job_id]

    # Build a small Python runner script that calls TradingAgents
    runner = f"""
import sys, os
sys.path.insert(0, "{TRADINGAGENTS_DIR}")
os.chdir("{TRADINGAGENTS_DIR}")

from tradingagents.graph.trading_graph import TradingAgentsGraph
from tradingagents.default_config import DEFAULT_CONFIG
import json, datetime

config = DEFAULT_CONFIG.copy()
config["llm_provider"]  = "anthropic"
config["deep_think_llm"] = "{model}"
config["quick_think_llm"] = "{model}"
config["results_dir"] = "{REPORTS_PATH}"

print("TASTART ticker={ticker} date={date}", flush=True)
ta = TradingAgentsGraph(debug=True, config=config)
state, decision = ta.propagate("{ticker}", "{date}")
print("TADONE", flush=True)
print("TADECISION " + json.dumps(str(decision)[:500]), flush=True)
"""

    env = {**os.environ, "PYTHONUNBUFFERED": "1"}

    try:
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-c", runner,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
        )
        job["proc"] = proc

        async for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace").rstrip()
            job["lines"].append({"t": time.time(), "text": line})

            if line.startswith("TADONE"):
                job["status"] = "done"
            elif line.startswith("TADECISION"):
                try:
                    job["decision"] = json.loads(line[len("TADECISION "):])
                except Exception:
                    pass

        await proc.wait()
        if proc.returncode != 0 and job["status"] != "done":
            job["status"] = "error"
        elif job["status"] != "done":
            job["status"] = "done"

    except Exception as exc:
        job["lines"].append({"t": time.time(), "text": f"[ERROR] {exc}"})
        job["status"] = "error"


@app.get("/run/{job_id}/stream")
async def stream_job(job_id: str):
    """SSE endpoint — streams log lines for a running or completed job."""
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")

    async def event_generator() -> AsyncGenerator[dict, None]:
        job    = JOBS[job_id]
        cursor = 0

        # Send all buffered lines first (catch-up for late subscribers)
        while True:
            while cursor < len(job["lines"]):
                entry = job["lines"][cursor]
                cursor += 1
                yield {"event": "log", "data": json.dumps(entry)}

            if job["status"] in ("done", "error"):
                yield {
                    "event": "done",
                    "data":  json.dumps({"status": job["status"], "job_id": job_id}),
                }
                return

            await asyncio.sleep(0.2)

    return EventSourceResponse(event_generator())


@app.get("/jobs")
async def list_jobs():
    """Return status of recent jobs (last 20)."""
    recent = sorted(JOBS.items(), key=lambda x: x[1]["created"], reverse=True)[:20]
    return [
        {
            "job_id":  jid,
            "status":  j["status"],
            "ticker":  j["ticker"],
            "date":    j["date"],
            "created": j["created"],
            "lines":   len(j["lines"]),
        }
        for jid, j in recent
    ]


@app.get("/health")
async def health():
    return {"ok": True, "reports_path": str(REPORTS_PATH), "reports_exist": REPORTS_PATH.exists()}
