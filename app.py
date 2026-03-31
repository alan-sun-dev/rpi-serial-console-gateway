#!/usr/bin/env python3
"""Console Gateway Web Management System (asyncio edition)"""

import os
import asyncio
import subprocess
import socket
import secrets
import functools
import json
import re
from datetime import datetime

from quart import Quart, render_template, request, jsonify, session, redirect, url_for
import socketio as sio_pkg
from werkzeug.security import generate_password_hash, check_password_hash

# --------------- Config ---------------
MAP_FILE = "/etc/console-gateway/map.tsv"
SESSION_LOG = "/var/log/console-gateway-sessions.log"
SECRET_KEY = os.environ.get("CGW_SECRET_KEY", secrets.token_hex(32))
ADMIN_USER = os.environ.get("CGW_ADMIN_USER", "admin")
# FIX: stored hash is now werkzeug pbkdf2 (salted), not bare SHA-256.
# Falls back to a default hash if env var missing.
ADMIN_PASS_HASH = os.environ.get("CGW_ADMIN_PASS_HASH", "")
if not ADMIN_PASS_HASH:
    ADMIN_PASS_HASH = generate_password_hash("consolegateway")
LISTEN_HOST = os.environ.get("CGW_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CGW_PORT", "8080"))

app = Quart(__name__)
app.secret_key = SECRET_KEY
sio = sio_pkg.AsyncServer(async_mode="asgi", cors_allowed_origins="*")
asgi_app = sio_pkg.ASGIApp(sio, app)

# Active terminal sessions: sid -> {"reader": StreamReader, "writer": StreamWriter}
terminal_sessions = {}


# --------------- Helpers ---------------
def verify_password(pw):
    """Verify password against stored hash (supports werkzeug and legacy sha256).
    FIX: backward compatible — if upgrading from v1.0 with a bare SHA-256 hash
    in the systemd env, login still works.
    """
    if ADMIN_PASS_HASH.startswith(("pbkdf2:", "scrypt:")):
        return check_password_hash(ADMIN_PASS_HASH, pw)
    # Legacy sha256 format (v1.0 installs)
    import hashlib
    return hashlib.sha256(pw.encode()).hexdigest() == ADMIN_PASS_HASH


def login_required(f):
    @functools.wraps(f)
    async def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            if request.is_json or request.headers.get("X-Requested-With"):
                return jsonify({"error": "unauthorized"}), 401
            return redirect(url_for("login"))
        return await f(*args, **kwargs)
    return decorated


def csrf_required(f):
    """Validate CSRF token on state-changing POST endpoints.
    FIX: X-Requested-With alone is NOT a reliable CSRF defence; a crafted
    same-origin form can set custom headers. We issue a per-session token and
    require it on every POST that mutates state.
    """
    @functools.wraps(f)
    async def decorated(*args, **kwargs):
        if request.method == "POST":
            token = request.headers.get("X-CSRF-Token") or (
                (await request.get_json(silent=True)) or {}
            ).get("_csrf")
            if not token or token != session.get("csrf_token"):
                return jsonify({"error": "invalid CSRF token"}), 403
        return await f(*args, **kwargs)
    return decorated


def read_map():
    """Read map.tsv and return list of port entries."""
    ports = []
    if not os.path.isfile(MAP_FILE):
        return ports
    with open(MAP_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            entry = {
                "device": parts[0],
                "port": int(parts[1]),
                "baud": int(parts[2]),
                "alias": parts[3] if len(parts) > 3 else "",
            }
            ports.append(entry)
    return ports


def get_allowed_ports():
    """Return set of TCP ports that are valid console bridge ports from map.tsv.
    FIX: used to whitelist WebSocket terminal connections so a logged-in user
    cannot pivot to localhost:22 or any other local service.
    """
    return {p["port"] for p in read_map()}


def get_port_status(device):
    """Check if bridge service is running and if someone is connected."""
    svc = f"console-lock-bridge@{device}.service"
    status = "stopped"
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "--quiet", svc],
            capture_output=True, timeout=5,
        )
        if r.returncode == 0:
            status = "running"
    except Exception:
        pass

    # Check if someone holds the lock
    owner = None
    owner_file = f"/run/console-gateway.{device}.owner"
    if os.path.isfile(owner_file):
        try:
            with open(owner_file) as f:
                owner = f.read().strip()
            if owner:
                status = "busy"
        except Exception:
            pass

    # Check symlink target
    link_target = None
    dev_path = f"/dev/{device}"
    if os.path.islink(dev_path):
        link_target = os.readlink(dev_path)
    elif os.path.exists(dev_path):
        link_target = "(direct)"
    else:
        link_target = "(missing)"
        status = "no-device"

    return {"status": status, "owner": owner, "link_target": link_target}


def get_all_ports():
    """Get all ports with their status."""
    ports = read_map()
    for p in ports:
        info = get_port_status(p["device"])
        p.update(info)
    return ports


def run_cmd(cmd, timeout=10):
    """Run a shell command and return (returncode, stdout, stderr).
    FIX: removed 'sudo' prefix from all callers — app.py runs as root under
    systemd, so sudo is redundant and can fail when sudoers is restricted.
    """
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as e:
        return -1, "", str(e)


def read_session_log(n=100):
    """Read last N lines of session log."""
    if not os.path.isfile(SESSION_LOG):
        return []
    try:
        r = subprocess.run(
            ["tail", "-n", str(n), SESSION_LOG],
            capture_output=True, text=True, timeout=5,
        )
        lines = r.stdout.strip().split("\n") if r.stdout.strip() else []
        return lines
    except Exception:
        return []


# --------------- Auth Routes ---------------
@app.route("/login", methods=["GET", "POST"])
async def login():
    if request.method == "POST":
        form = await request.form
        username = form.get("username", "")
        password = form.get("password", "")
        # FIX: verify_password handles both werkzeug pbkdf2 and legacy sha256.
        if username == ADMIN_USER and verify_password(password):
            session.clear()
            session["logged_in"] = True
            session["username"] = username
            # Issue a fresh CSRF token per login session.
            session["csrf_token"] = secrets.token_hex(32)
            return redirect(url_for("dashboard"))
        return await render_template("login.html", error="Invalid credentials")
    return await render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# --------------- Page Routes ---------------
@app.route("/")
@login_required
async def dashboard():
    # Expose CSRF token to the template so JS can read it.
    return await render_template("dashboard.html", csrf_token=session.get("csrf_token", ""))


@app.route("/terminal")
@login_required
async def terminal_page():
    port = request.args.get("port", type=int)
    if not port:
        return redirect(url_for("dashboard"))
    allowed = get_allowed_ports()
    if port not in allowed:
        return "Port not allowed", 403
    # Find alias for display
    alias = ""
    for p in read_map():
        if p["port"] == port:
            alias = p.get("alias", "")
            break
    return await render_template("terminal.html", port=port, alias=alias)


# --------------- API Routes ---------------
@app.route("/api/ports")
@login_required
async def api_ports():
    return jsonify(get_all_ports())


@app.route("/api/ports/<device>/restart", methods=["POST"])
@login_required
@csrf_required
async def api_restart_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "restart", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Restarted {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/kick", methods=["POST"])
@login_required
@csrf_required
async def api_kick_port(device):
    """FIX: kick now actually disconnects the active session before restarting.
    Previously this was identical to restart — a no-op for the current holder.
    Now we use fuser to SIGTERM the socat process holding /dev/<device>, then
    remove the owner/lock files, then restart the bridge unit.
    """
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400

    lock_file = f"/run/console-gateway.{device}.lock"
    owner_file = f"/run/console-gateway.{device}.owner"

    # Step 1: kill any process holding the device node (SIGTERM, then SIGKILL)
    run_cmd(["fuser", "-k", "-TERM", f"/dev/{device}"], timeout=5)
    await asyncio.sleep(0.5)
    run_cmd(["fuser", "-k", "-KILL", f"/dev/{device}"], timeout=5)

    # Step 2: clean up stale lock/owner files
    for path in (lock_file, owner_file):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass

    # Step 3: restart the bridge so it's ready for the next connection
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "restart", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Kicked active session on {device}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/unlock", methods=["POST"])
@login_required
@csrf_required
async def api_unlock_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    lock_file = f"/run/console-gateway.{device}.lock"
    owner_file = f"/run/console-gateway.{device}.owner"

    # Kill holder, clean up files.
    run_cmd(["fuser", "-k", "-TERM", f"/dev/{device}"], timeout=5)
    for path in (lock_file, owner_file):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    return jsonify({"ok": True, "message": f"Unlocked {device}"})


@app.route("/api/ports/<device>/stop", methods=["POST"])
@login_required
@csrf_required
async def api_stop_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "stop", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Stopped {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/start", methods=["POST"])
@login_required
@csrf_required
async def api_start_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "start", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Started {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/rename", methods=["POST"])
@login_required
@csrf_required
async def api_rename_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    data = await request.get_json() or {}
    new_alias = data.get("alias", "").strip()
    if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}$', new_alias):
        return jsonify({"error": "Invalid alias. Use letters, digits, hyphens, underscores (1-60 chars)."}), 400

    lines = []
    found = False
    if not os.path.isfile(MAP_FILE):
        return jsonify({"error": "map.tsv not found"}), 404
    with open(MAP_FILE) as f:
        for line in f:
            raw = line.rstrip("\n")
            if raw.startswith("#") or not raw.strip():
                lines.append(raw)
                continue
            parts = raw.split("\t")
            if len(parts) >= 3 and parts[0] == device:
                found = True
                while len(parts) < 4:
                    parts.append("")
                parts[3] = new_alias
                lines.append("\t".join(parts))
            else:
                lines.append(raw)
    if not found:
        return jsonify({"error": f"Device {device} not found in map"}), 404

    with open(MAP_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")

    return jsonify({"ok": True, "message": f"Alias updated to '{new_alias}'"})


@app.route("/api/status")
@login_required
async def api_status():
    hostname = socket.gethostname()
    rc_ssh, _, _ = run_cmd(["systemctl", "is-active", "--quiet", "ssh"])
    if rc_ssh != 0:
        rc_ssh, _, _ = run_cmd(["systemctl", "is-active", "--quiet", "sshd"])
    rc_ts, ts_out, _ = run_cmd(["tailscale", "status", "--json"])
    tailscale_ip = None
    if rc_ts == 0:
        try:
            ts_data = json.loads(ts_out)
            addrs = ts_data.get("Self", {}).get("TailscaleIPs", [])
            if addrs:
                tailscale_ip = addrs[0]
        except Exception:
            pass

    return jsonify({
        "hostname": hostname,
        "ssh": "ok" if rc_ssh == 0 else "down",
        "tailscale": "ok" if rc_ts == 0 else "not connected",
        "tailscale_ip": tailscale_ip,
        "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    })


@app.route("/api/sessions")
@login_required
async def api_sessions():
    n = request.args.get("n", 100, type=int)
    lines = read_session_log(min(n, 1000))
    return jsonify(lines)


@app.route("/api/detect")
@login_required
async def api_detect():
    rc, out, err = run_cmd(["console-detect"], timeout=15)
    return jsonify({"output": out if rc == 0 else err})


# --------------- Settings API ---------------
DROPIN_DIR = "/etc/systemd/system"
WEB_SERVICE = "console-gateway-web"


def read_port_settings(device):
    """Read per-port settings from systemd drop-in."""
    conf = f"{DROPIN_DIR}/console-lock-bridge@{device}.service.d/10-env.conf"
    settings = {}
    if os.path.isfile(conf):
        with open(conf) as f:
            for line in f:
                m = re.match(r'^Environment=(\w+)=(.+)$', line.strip())
                if m:
                    settings[m.group(1)] = m.group(2)
    return settings


def _write_dropin(device, settings_dict):
    """Write (or create) the systemd drop-in for a device.
    FIX: previously returned 404 if drop-in was missing; now auto-creates it.
    """
    conf_dir = f"{DROPIN_DIR}/console-lock-bridge@{device}.service.d"
    conf_file = f"{conf_dir}/10-env.conf"
    os.makedirs(conf_dir, exist_ok=True)
    content = "[Service]\n"
    for k, v in settings_dict.items():
        content += f"Environment={k}={v}\n"
    with open(conf_file, "w") as f:
        f.write(content)


@app.route("/api/settings/ports")
@login_required
async def api_settings_ports():
    """Get all port settings."""
    ports = read_map()
    result = []
    for p in ports:
        s = read_port_settings(p["device"])
        result.append({
            "device": p["device"],
            "alias": p.get("alias", ""),
            "port": p["port"],
            "baud": int(s.get("CONSOLE_BAUD", p["baud"])),
            "idle_timeout": int(s.get("IDLE_TIMEOUT_SECONDS", 900)),
            "max_session": int(s.get("MAX_SESSION_SECONDS", 3600)),
        })
    return jsonify(result)


@app.route("/api/settings/ports/<device>", methods=["POST"])
@login_required
@csrf_required
async def api_settings_port_update(device):
    """Update per-port settings."""
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400

    data = await request.get_json() or {}
    baud = data.get("baud")
    idle_timeout = data.get("idle_timeout")
    max_session = data.get("max_session")

    valid_bauds = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200]
    if baud is not None and int(baud) not in valid_bauds:
        return jsonify({"error": f"Invalid baud rate. Valid: {valid_bauds}"}), 400
    if idle_timeout is not None and (int(idle_timeout) < 30 or int(idle_timeout) > 86400):
        return jsonify({"error": "Idle timeout must be 30-86400 seconds"}), 400
    if max_session is not None and (int(max_session) < 60 or int(max_session) > 604800):
        return jsonify({"error": "Max session must be 60-604800 seconds"}), 400

    # FIX: read existing drop-in if present; otherwise start from map defaults.
    # Previously returned 404 when the drop-in file didn't exist.
    current = read_port_settings(device)
    if not current:
        port_entry = next((p for p in read_map() if p["device"] == device), None)
        if port_entry is None:
            return jsonify({"error": f"Device {device} not found in map"}), 404
        current = {
            "CONSOLE_DEV": f"/dev/{device}",
            "CONSOLE_BAUD": str(port_entry["baud"]),
            "LOCAL_CONSOLE_PORT": str(port_entry["port"]),
            "IDLE_TIMEOUT_SECONDS": "900",
            "MAX_SESSION_SECONDS": "3600",
        }

    if baud is not None:
        current["CONSOLE_BAUD"] = str(int(baud))
    if idle_timeout is not None:
        current["IDLE_TIMEOUT_SECONDS"] = str(int(idle_timeout))
    if max_session is not None:
        current["MAX_SESSION_SECONDS"] = str(int(max_session))

    # Also update baud in map.tsv for consistency
    if baud is not None and os.path.isfile(MAP_FILE):
        map_lines = []
        with open(MAP_FILE) as f:
            for line in f:
                raw = line.rstrip("\n")
                if raw.startswith("#") or not raw.strip():
                    map_lines.append(raw)
                    continue
                parts = raw.split("\t")
                if len(parts) >= 3 and parts[0] == device:
                    parts[2] = str(int(baud))
                    map_lines.append("\t".join(parts))
                else:
                    map_lines.append(raw)
        with open(MAP_FILE, "w") as f:
            f.write("\n".join(map_lines) + "\n")

    # Write drop-in (create if needed)
    _write_dropin(device, current)

    run_cmd(["systemctl", "daemon-reload"])
    run_cmd(["systemctl", "restart", f"console-lock-bridge@{device}.service"])

    return jsonify({"ok": True, "message": f"Settings updated for {device}"})


@app.route("/api/settings/global")
@login_required
async def api_settings_global():
    """Get global settings."""
    template = f"{DROPIN_DIR}/console-lock-bridge@.service"
    defaults = {}
    if os.path.isfile(template):
        with open(template) as f:
            for line in f:
                m = re.match(r'^Environment=(\w+)=(.+)$', line.strip())
                if m:
                    defaults[m.group(1)] = m.group(2)

    web_conf = f"{DROPIN_DIR}/{WEB_SERVICE}.service"
    web_settings = {}
    if os.path.isfile(web_conf):
        with open(web_conf) as f:
            for line in f:
                m = re.match(r'^Environment=(\w+)=(.+)$', line.strip())
                if m:
                    web_settings[m.group(1)] = m.group(2)

    allow_users = ""
    ssh_conf = "/etc/ssh/sshd_config.d/90-console-gateway.conf"
    if os.path.isfile(ssh_conf):
        with open(ssh_conf) as f:
            for line in f:
                if line.strip().startswith("AllowUsers"):
                    parts = line.strip().split(None, 1)
                    allow_users = parts[1] if len(parts) > 1 else ""

    return jsonify({
        "console": {
            "port_base": int(defaults.get("LOCAL_CONSOLE_PORT", 2001)),
            "default_baud": int(defaults.get("CONSOLE_BAUD", 9600)),
            "idle_timeout": int(defaults.get("IDLE_TIMEOUT_SECONDS", 900)),
            "max_session": int(defaults.get("MAX_SESSION_SECONDS", 3600)),
        },
        "web": {
            "host": web_settings.get("CGW_HOST", "0.0.0.0"),
            "port": int(web_settings.get("CGW_PORT", 8080)),
            "admin_user": web_settings.get("CGW_ADMIN_USER", "admin"),
        },
        "ssh": {"allow_users": allow_users},
    })


@app.route("/api/settings/global", methods=["POST"])
@login_required
@csrf_required
async def api_settings_global_update():
    """Update global defaults in the systemd template."""
    data = await request.get_json() or {}
    valid_bauds = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200]
    baud = data.get("default_baud")
    idle = data.get("idle_timeout")
    maxs = data.get("max_session")

    if baud is not None and int(baud) not in valid_bauds:
        return jsonify({"error": "Invalid baud rate"}), 400
    if idle is not None and (int(idle) < 30 or int(idle) > 86400):
        return jsonify({"error": "Idle timeout must be 30-86400"}), 400
    if maxs is not None and (int(maxs) < 60 or int(maxs) > 604800):
        return jsonify({"error": "Max session must be 60-604800"}), 400

    template = f"{DROPIN_DIR}/console-lock-bridge@.service"
    if not os.path.isfile(template):
        return jsonify({"error": "Template service not found"}), 404

    with open(template) as f:
        content = f.read()

    if baud is not None:
        content = re.sub(r'Environment=CONSOLE_BAUD=\d+',
                         f'Environment=CONSOLE_BAUD={int(baud)}', content)
    if idle is not None:
        content = re.sub(r'Environment=IDLE_TIMEOUT_SECONDS=\d+',
                         f'Environment=IDLE_TIMEOUT_SECONDS={int(idle)}', content)
    if maxs is not None:
        content = re.sub(r'Environment=MAX_SESSION_SECONDS=\d+',
                         f'Environment=MAX_SESSION_SECONDS={int(maxs)}', content)

    with open(template, "w") as f:
        f.write(content)

    run_cmd(["systemctl", "daemon-reload"])
    return jsonify({"ok": True, "message": "Global defaults updated."})


# --------------- Network / iPhone Gateway API ---------------
CGW_NETWORK_STATE = "/run/cgw-network.state"
CGW_IPHONE_UP = "/usr/local/sbin/cgw-iphone-up"
CGW_IPHONE_DOWN = "/usr/local/sbin/cgw-iphone-down"


def _read_kv_file(path):
    """Parse a key=value status file."""
    data = {}
    if not os.path.isfile(path):
        return data
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    data[k.strip()] = v.strip()
    except Exception:
        pass
    return data


def _iface_ip(iface):
    """Get IPv4 address of a network interface."""
    try:
        r = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", iface],
            capture_output=True, text=True, timeout=5,
        )
        for part in r.stdout.split():
            if "/" in part and "." in part:
                return part.split("/")[0]
    except Exception:
        pass
    return None


def _iface_stats(iface):
    """Read RX/TX byte counters from sysfs."""
    def _read(name):
        try:
            with open(f"/sys/class/net/{iface}/statistics/{name}") as f:
                return int(f.read().strip())
        except Exception:
            return 0
    return {"rx_bytes": _read("rx_bytes"), "tx_bytes": _read("tx_bytes")}


def _sys_val(iface, item):
    """Read a value from /sys/class/net/<iface>/<item>."""
    try:
        with open(f"/sys/class/net/{iface}/{item}") as f:
            return f.read().strip()
    except Exception:
        return ""


def _service_active(name):
    try:
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", name],
            capture_output=True, timeout=5,
        ).returncode == 0
    except Exception:
        return False


def _detect_usb_wan():
    """Detect USB network interface (iPhone tethering)."""
    try:
        r = subprocess.run(
            ["ip", "-o", "link", "show"],
            capture_output=True, text=True, timeout=5,
        )
        for line in r.stdout.strip().split("\n"):
            parts = line.split(": ")
            if len(parts) >= 2:
                dev = parts[1].split("@")[0].strip()
                if re.match(r'^(usb|enx|eth[1-9]|wwan)', dev):
                    return dev
    except Exception:
        pass
    return None


def _list_interfaces():
    """List all network interfaces with basic info."""
    ifaces = []
    try:
        r = subprocess.run(
            ["ip", "-4", "-o", "addr", "show"],
            capture_output=True, text=True, timeout=5,
        )
        seen = set()
        for line in r.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split()
            # format: idx: dev inet x.x.x.x/prefix ...
            dev = parts[1] if len(parts) > 1 else ""
            if dev in seen or dev == "lo":
                continue
            seen.add(dev)
            ip_addr = None
            for i, p in enumerate(parts):
                if p == "inet" and i + 1 < len(parts):
                    ip_addr = parts[i + 1].split("/")[0]
                    break
            op = _sys_val(dev, "operstate")
            ifaces.append({
                "name": dev,
                "ip": ip_addr,
                "operstate": op,
            })
        # Also list interfaces without IP (link up but no addr)
        r2 = subprocess.run(
            ["ip", "-o", "link", "show"],
            capture_output=True, text=True, timeout=5,
        )
        for line in r2.stdout.strip().split("\n"):
            lparts = line.split(": ")
            if len(lparts) >= 2:
                dev = lparts[1].split("@")[0].strip()
                if dev not in seen and dev != "lo":
                    seen.add(dev)
                    op = _sys_val(dev, "operstate")
                    ifaces.append({"name": dev, "ip": None, "operstate": op})
    except Exception:
        pass
    return ifaces


@app.route("/api/network/status")
@login_required
async def api_network_status():
    """Comprehensive network status: mode, interfaces, gateway details."""
    gw_installed = os.path.isfile(CGW_IPHONE_UP)

    # Current mode from state file
    state = _read_kv_file(CGW_NETWORK_STATE)
    mode = state.get("mode", "normal")
    wan_if = state.get("wan_if", "")

    # Detect USB WAN interface (iPhone)
    usb_wan = _detect_usb_wan()

    # All interfaces
    interfaces = _list_interfaces()

    # Default route
    try:
        r = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True, text=True, timeout=5,
        )
        default_route = r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""
    except Exception:
        default_route = ""

    # iPhone pair status (only check if relevant)
    paired = False
    pair_msg = ""
    if usb_wan or mode == "iphone-gw":
        rc, out, _ = run_cmd(["idevicepair", "validate"], timeout=5)
        paired = rc == 0
        pair_msg = out.strip() if out else ""

    # Gateway mode details
    gw_info = {}
    if mode == "iphone-gw" and wan_if:
        wan_ip = _iface_ip(wan_if)
        wan_ready = _sys_val(wan_if, "operstate") == "up"
        stats = _iface_stats(wan_if)
        gw_info = {
            "wan_if": wan_if,
            "wan_ip": wan_ip,
            "wan_ready": wan_ready,
            "lan_ip": _iface_ip("eth0"),
            "rx_bytes": stats["rx_bytes"],
            "tx_bytes": stats["tx_bytes"],
            "activated": state.get("activated", ""),
        }

    return jsonify({
        "mode": mode,
        "gw_installed": gw_installed,
        "iphone_detected": usb_wan is not None,
        "usb_wan_if": usb_wan,
        "iphone_paired": paired,
        "pair_message": pair_msg,
        "interfaces": interfaces,
        "default_route": default_route,
        "gateway": gw_info,
    })


@app.route("/api/network/iphone-gw/enable", methods=["POST"])
@login_required
@csrf_required
async def api_iphone_gw_enable():
    """Manually activate iPhone gateway mode."""
    if not os.path.isfile(CGW_IPHONE_UP):
        return jsonify({"error": "iPhone gateway scripts not installed"}), 400
    rc, out, err = run_cmd([CGW_IPHONE_UP], timeout=30)
    combined = (out + err).strip()
    if rc == 0:
        return jsonify({"ok": True, "message": combined or "iPhone gateway activated"})
    return jsonify({"error": combined or "Activation failed"}), 500


@app.route("/api/network/iphone-gw/disable", methods=["POST"])
@login_required
@csrf_required
async def api_iphone_gw_disable():
    """Manually deactivate iPhone gateway mode."""
    if not os.path.isfile(CGW_IPHONE_DOWN):
        return jsonify({"error": "iPhone gateway scripts not installed"}), 400
    rc, out, err = run_cmd([CGW_IPHONE_DOWN], timeout=30)
    combined = (out + err).strip()
    if rc == 0:
        return jsonify({"ok": True, "message": combined or "iPhone gateway deactivated"})
    return jsonify({"error": combined or "Deactivation failed"}), 500


@app.route("/api/iphone/pair", methods=["POST"])
@login_required
@csrf_required
async def api_iphone_pair():
    """Trigger idevicepair pair (iPhone must show Trust dialog)."""
    rc, out, err = run_cmd(["idevicepair", "pair"], timeout=15)
    combined = (out + err).strip()
    if rc == 0 or "SUCCESS" in combined.upper():
        return jsonify({"ok": True, "message": combined or "Paired successfully"})
    return jsonify({"ok": False, "error": combined or "Pair failed. Tap 'Trust' on iPhone."}), 400


# --------------- Tailscale API ---------------
@app.route("/api/tailscale/status")
@login_required
async def api_tailscale_status():
    rc, out, err = run_cmd(["tailscale", "status", "--json"], timeout=10)
    if rc != 0:
        rc2, _, _ = run_cmd(["systemctl", "is-active", "--quiet", "tailscaled"])
        return jsonify({
            "state": "stopped" if rc2 != 0 else "needs_login",
            "daemon_running": rc2 == 0,
            "error": err,
        })
    try:
        data = json.loads(out)
        self_node = data.get("Self", {})
        peers = {}
        for key, peer in (data.get("Peer") or {}).items():
            peers[key] = {
                "hostname": peer.get("HostName", ""),
                "dns_name": peer.get("DNSName", ""),
                "ips": peer.get("TailscaleIPs", []),
                "os": peer.get("OS", ""),
                "online": peer.get("Online", False),
                "active": peer.get("Active", False),
                "last_seen": peer.get("LastSeen", ""),
                "rx_bytes": peer.get("RxBytes", 0),
                "tx_bytes": peer.get("TxBytes", 0),
            }
        auth_url = data.get("AuthURL", "")
        return jsonify({
            "state": data.get("BackendState", "Unknown"),
            "daemon_running": True,
            "auth_url": auth_url if auth_url else None,
            "self": {
                "hostname": self_node.get("HostName", ""),
                "dns_name": self_node.get("DNSName", ""),
                "ips": self_node.get("TailscaleIPs", []),
                "os": self_node.get("OS", ""),
                "online": self_node.get("Online", False),
                "tailnet": data.get("MagicDNSSuffix", ""),
            },
            "peers": peers,
        })
    except Exception as e:
        return jsonify({"state": "error", "error": str(e)})


@app.route("/api/tailscale/up", methods=["POST"])
@login_required
@csrf_required
async def api_tailscale_up():
    rc, out, err = run_cmd(["tailscale", "up"], timeout=15)
    combined = (out + err).strip()
    login_url = None
    for line in combined.split("\n"):
        line = line.strip()
        if line.startswith("https://login.tailscale.com/"):
            login_url = line
            break
    if login_url:
        return jsonify({"ok": True, "needs_auth": True, "auth_url": login_url})
    return jsonify({"ok": rc == 0, "message": combined})


@app.route("/api/tailscale/down", methods=["POST"])
@login_required
@csrf_required
async def api_tailscale_down():
    rc, out, err = run_cmd(["tailscale", "down"], timeout=10)
    if rc == 0:
        return jsonify({"ok": True, "message": "Tailscale disconnected"})
    return jsonify({"error": err}), 500


@app.route("/api/tailscale/ping", methods=["POST"])
@login_required
@csrf_required
async def api_tailscale_ping():
    target = (await request.get_json()).get("target", "") if request.is_json else ""
    if not target or not re.match(r'^[a-zA-Z0-9._-]+$', target):
        return jsonify({"error": "invalid target"}), 400
    rc, out, err = run_cmd(["tailscale", "ping", "-c", "3", target], timeout=15)
    return jsonify({"ok": rc == 0, "output": out if rc == 0 else err})


# --------------- WebSocket Terminal ---------------
# python-socketio AsyncServer uses (sid, ...) signatures instead of Flask-
# SocketIO's implicit ``request.sid``.  The Quart session cookie is forwarded
# on the HTTP upgrade request; we parse it in the ``connect`` handler and
# store authenticated SIDs in a server-side set.

_authenticated_sids: set[str] = set()


@sio.on("connect", namespace="/terminal")
async def terminal_connect(sid, environ, auth=None):
    """Validate the Quart session cookie from the HTTP upgrade headers."""
    from quart.sessions import SecureCookieSessionInterface
    from http.cookies import SimpleCookie

    cookie_header = environ.get("HTTP_COOKIE", "")
    cookie = SimpleCookie(cookie_header)
    morsel = cookie.get("session")
    if not morsel:
        await sio.disconnect(sid, namespace="/terminal")
        return

    # Decode the itsdangerous-signed session cookie
    iface = SecureCookieSessionInterface()
    serializer = iface.get_signing_serializer(app)
    if serializer is None:
        await sio.disconnect(sid, namespace="/terminal")
        return
    sess_data = serializer.loads(morsel.value)
    if not sess_data or not sess_data.get("logged_in"):
        await sio.disconnect(sid, namespace="/terminal")
        return

    _authenticated_sids.add(sid)


@sio.on("open_terminal", namespace="/terminal")
async def open_terminal(sid, data):
    """FIX: validate that the requested port is in the allowed port whitelist
    from map.tsv before connecting. Without this, an authenticated user could
    connect to any localhost service (e.g. :22 SSH, :5432 postgres, etc.).
    """
    if sid not in _authenticated_sids:
        await sio.disconnect(sid, namespace="/terminal")
        return

    port = data.get("port")
    if not port or not str(port).isdigit():
        await sio.emit("terminal_output", {"data": "[error] Invalid port\r\n"},
                        namespace="/terminal", to=sid)
        return

    port = int(port)

    # Whitelist check — only allow ports declared in map.tsv
    allowed = get_allowed_ports()
    if port not in allowed:
        await sio.emit("terminal_output", {
            "data": f"[error] Port {port} is not an allowed console port\r\n"
        }, namespace="/terminal", to=sid)
        return

    # Close existing session if any
    old = terminal_sessions.pop(sid, None)
    if old:
        old["writer"].close()

    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        terminal_sessions[sid] = {"reader": reader, "writer": writer}
        await sio.emit("terminal_output",
                        {"data": f"[connected] localhost:{port}\r\n"},
                        namespace="/terminal", to=sid)

        async def read_loop():
            try:
                while sid in terminal_sessions:
                    chunk = await reader.read(4096)
                    if not chunk:
                        break
                    await sio.emit(
                        "terminal_output",
                        {"data": chunk.decode("utf-8", errors="replace")},
                        namespace="/terminal",
                        to=sid,
                    )
            except Exception:
                pass
            finally:
                await sio.emit(
                    "terminal_output",
                    {"data": "\r\n[disconnected]\r\n"},
                    namespace="/terminal",
                    to=sid,
                )
                sess = terminal_sessions.pop(sid, None)
                if sess:
                    sess["writer"].close()

        asyncio.create_task(read_loop())

    except Exception as e:
        await sio.emit("terminal_output",
                        {"data": f"[error] Cannot connect: {e}\r\n"},
                        namespace="/terminal", to=sid)


@sio.on("terminal_input", namespace="/terminal")
async def terminal_input(sid, data):
    sess = terminal_sessions.get(sid)
    if sess:
        try:
            sess["writer"].write(data.get("data", "").encode("utf-8"))
            await sess["writer"].drain()
        except Exception:
            pass


@sio.on("close_terminal", namespace="/terminal")
async def close_terminal(sid):
    sess = terminal_sessions.pop(sid, None)
    if sess:
        sess["writer"].close()
    _authenticated_sids.discard(sid)


@sio.on("disconnect", namespace="/terminal")
async def terminal_disconnect(sid):
    sess = terminal_sessions.pop(sid, None)
    if sess:
        sess["writer"].close()
    _authenticated_sids.discard(sid)


if __name__ == "__main__":
    import uvicorn
    print(f"Console Gateway Web - http://{LISTEN_HOST}:{LISTEN_PORT}")
    uvicorn.run(asgi_app, host=LISTEN_HOST, port=LISTEN_PORT)
