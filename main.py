#!/usr/bin/env python3
"""
Peach - iOS Backup Manager for Linux
Backend API server
"""

import asyncio
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ── Config ────────────────────────────────────────────────────────────────────

CONFIG_PATH = Path(os.environ.get("PEACH_CONFIG", "/etc/peach/config.json"))
STATIC_DIR = Path(os.environ.get("PEACH_STATIC", "/opt/peach/ui"))


def load_config() -> dict:
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {"backup_dir": str(Path.home() / "peach-backups")}


def save_config(data: dict):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(data, indent=2))


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="Peach", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Active WebSocket connections for log streaming
active_connections: list[WebSocket] = []

# Current backup process
current_backup: Optional[asyncio.subprocess.Process] = None
backup_running = False


# ── Helpers ───────────────────────────────────────────────────────────────────

def run_cmd(args: list[str]) -> tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)."""
    result = subprocess.run(args, capture_output=True, text=True, timeout=10)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def get_connected_devices() -> list[dict]:
    """Return list of connected iOS devices via idevice_id."""
    rc, out, _ = run_cmd(["idevice_id", "-l"])
    if rc != 0 or not out:
        return []

    devices = []
    for udid in out.splitlines():
        udid = udid.strip()
        if not udid:
            continue

        name = "Unknown Device"
        rc2, info, _ = run_cmd(["ideviceinfo", "-u", udid, "-k", "DeviceName"])
        if rc2 == 0 and info:
            name = info

        model = ""
        rc3, m, _ = run_cmd(["ideviceinfo", "-u", udid, "-k", "ProductType"])
        if rc3 == 0 and m:
            model = m

        ios = ""
        rc4, v, _ = run_cmd(["ideviceinfo", "-u", udid, "-k", "ProductVersion"])
        if rc4 == 0 and v:
            ios = v

        devices.append({"udid": udid, "name": name, "model": model, "ios": ios})

    return devices


def get_backups(backup_dir: str) -> list[dict]:
    """Scan backup directory for existing backups."""
    base = Path(backup_dir)
    if not base.exists():
        return []

    backups = []
    for item in sorted(base.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if not item.is_dir():
            continue
        info_file = item / "Info.plist"
        manifest = item / "Manifest.plist"
        if not manifest.exists():
            continue

        size = sum(f.stat().st_size for f in item.rglob("*") if f.is_file())
        mtime = datetime.fromtimestamp(item.stat().st_mtime)

        # Try to extract device name from Info.plist via ideviceinfo-style plutil
        device_name = item.name
        try:
            rc, out, _ = run_cmd(["plutil", "-p", str(info_file)])
            if rc == 0:
                m = re.search(r'"Device Name"\s*=>\s*"([^"]+)"', out)
                if m:
                    device_name = m.group(1)
        except Exception:
            pass

        backups.append({
            "id": item.name,
            "device_name": device_name,
            "path": str(item),
            "size_bytes": size,
            "size_human": _human_size(size),
            "date": mtime.isoformat(),
            "date_human": mtime.strftime("%b %d, %Y %I:%M %p"),
        })

    return backups


def _human_size(b: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


async def broadcast(msg: dict):
    """Send a message to all connected WebSocket clients."""
    dead = []
    for ws in active_connections:
        try:
            await ws.send_json(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        active_connections.remove(ws)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/api/status")
def status():
    cfg = load_config()
    devices = get_connected_devices()
    return {
        "backup_dir": cfg.get("backup_dir", ""),
        "devices": devices,
        "backup_running": backup_running,
    }


@app.get("/api/devices")
def devices():
    return {"devices": get_connected_devices()}


@app.get("/api/backups")
def backups():
    cfg = load_config()
    return {"backups": get_backups(cfg.get("backup_dir", ""))}


@app.post("/api/config")
async def update_config(body: dict):
    cfg = load_config()
    if "backup_dir" in body:
        cfg["backup_dir"] = body["backup_dir"]
        Path(cfg["backup_dir"]).mkdir(parents=True, exist_ok=True)
    save_config(cfg)
    return {"ok": True, "config": cfg}


@app.post("/api/backup/start")
async def start_backup(body: dict):
    global current_backup, backup_running

    if backup_running:
        return JSONResponse({"error": "Backup already in progress"}, status_code=409)

    udid = body.get("udid")
    if not udid:
        return JSONResponse({"error": "No UDID provided"}, status_code=400)

    cfg = load_config()
    backup_dir = cfg.get("backup_dir", str(Path.home() / "peach-backups"))
    Path(backup_dir).mkdir(parents=True, exist_ok=True)

    asyncio.create_task(_run_backup(udid, backup_dir))
    return {"ok": True, "message": "Backup started"}


@app.post("/api/backup/cancel")
async def cancel_backup():
    global current_backup, backup_running
    if current_backup and backup_running:
        current_backup.terminate()
        backup_running = False
        await broadcast({"type": "log", "message": "⚠ Backup cancelled by user."})
        await broadcast({"type": "status", "running": False, "success": False})
    return {"ok": True}


async def _run_backup(udid: str, backup_dir: str):
    global current_backup, backup_running
    backup_running = True

    await broadcast({"type": "status", "running": True})
    await broadcast({"type": "log", "message": f"🍑 Starting backup for {udid}..."})
    await broadcast({"type": "log", "message": f"📁 Destination: {backup_dir}"})

    try:
        current_backup = await asyncio.create_subprocess_exec(
            "idevicebackup2", "backup", "--full", backup_dir,
            "-u", udid,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )

        async for line in current_backup.stdout:
            text = line.decode(errors="replace").rstrip()
            if text:
                await broadcast({"type": "log", "message": text})

        await current_backup.wait()
        success = current_backup.returncode == 0

        if success:
            await broadcast({"type": "log", "message": "✅ Backup completed successfully!"})
        else:
            await broadcast({"type": "log", "message": f"❌ Backup failed (exit {current_backup.returncode})"})

        await broadcast({"type": "status", "running": False, "success": success})

    except Exception as e:
        await broadcast({"type": "log", "message": f"❌ Error: {e}"})
        await broadcast({"type": "status", "running": False, "success": False})
    finally:
        backup_running = False
        current_backup = None


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    active_connections.append(ws)
    try:
        # Send current state on connect
        cfg = load_config()
        devices = get_connected_devices()
        await ws.send_json({
            "type": "init",
            "backup_dir": cfg.get("backup_dir", ""),
            "devices": devices,
            "backup_running": backup_running,
        })
        while True:
            await ws.receive_text()  # keep alive
    except WebSocketDisconnect:
        if ws in active_connections:
            active_connections.remove(ws)


# ── Static UI ─────────────────────────────────────────────────────────────────

@app.get("/")
async def serve_index():
    return FileResponse(str(STATIC_DIR / "index.html"))

if STATIC_DIR.exists():
    app.mount("/assets", StaticFiles(directory=str(STATIC_DIR)), name="ui")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=5173, reload=False)
