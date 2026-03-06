#!/usr/bin/env bash
# Console Gateway Web Management - Installer
# Installs the web UI on top of an existing Console Gateway v2.9 setup.
# Usage: sudo bash install-web.sh [--port 8080] [--password mypass]
set -euo pipefail

# ====== Defaults ======
INSTALL_DIR="/opt/console-gateway-web"
CGW_PORT="${CGW_PORT:-8080}"
CGW_HOST="${CGW_HOST:-0.0.0.0}"
CGW_ADMIN_USER="${CGW_ADMIN_USER:-admin}"
CGW_ADMIN_PASS="${CGW_ADMIN_PASS:-consolegateway}"
SERVICE_NAME="console-gateway-web"

# ====== Parse args ======
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     CGW_PORT="$2"; shift 2 ;;
    --password) CGW_ADMIN_PASS="$2"; shift 2 ;;
    --user)     CGW_ADMIN_USER="$2"; shift 2 ;;
    --host)     CGW_HOST="$2"; shift 2 ;;
    --dir)      INSTALL_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: sudo $0 [OPTIONS]"
      echo "  --port PORT       Web UI port (default: 8080)"
      echo "  --password PASS   Admin password (default: consolegateway)"
      echo "  --user USER       Admin username (default: admin)"
      echo "  --host HOST       Listen address (default: 0.0.0.0)"
      echo "  --dir DIR         Install directory (default: /opt/console-gateway-web)"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ====== Checks ======
[[ "${EUID}" -eq 0 ]] || { echo "Error: run as root (sudo $0)"; exit 1; }

if [[ ! -f /etc/console-gateway/map.tsv ]]; then
  echo "Error: Console Gateway v2.9 not found (/etc/console-gateway/map.tsv missing)."
  echo "Install it first: https://github.com/alan-sun-dev/rpi-serial-console-gateway"
  exit 1
fi

log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

# ====== Password hash (computed after venv is ready) ======
# Deferred until werkzeug is installed in venv

# ====== Install system packages ======
log "Installing system packages..."
apt-get update -y -qq
apt-get install -y -qq python3-venv python3-dev > /dev/null

# ====== Create install directory ======
log "Creating ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/templates"

# ====== Write app.py ======
log "Writing app.py..."
cat > "${INSTALL_DIR}/app.py" <<'APPEOF'
#!/usr/bin/env python3
"""Console Gateway Web Management System"""

import eventlet
eventlet.monkey_patch()

import os
import subprocess
import socket
import secrets
import functools
import json
import re
from datetime import datetime

from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from flask_socketio import SocketIO, emit, disconnect
from werkzeug.security import generate_password_hash, check_password_hash

# --------------- Config ---------------
MAP_FILE = "/etc/console-gateway/map.tsv"
SESSION_LOG = "/var/log/console-gateway-sessions.log"
SECRET_KEY = os.environ.get("CGW_SECRET_KEY", secrets.token_hex(32))
ADMIN_USER = os.environ.get("CGW_ADMIN_USER", "admin")
# Support both new (werkzeug) and legacy (sha256) hash formats
ADMIN_PASS_HASH = os.environ.get("CGW_ADMIN_PASS_HASH", "")
if not ADMIN_PASS_HASH:
    ADMIN_PASS_HASH = generate_password_hash("consolegateway")
LISTEN_HOST = os.environ.get("CGW_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CGW_PORT", "8080"))

app = Flask(__name__)
app.secret_key = SECRET_KEY
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

# Active terminal sessions: sid -> socket object
terminal_sessions = {}


# --------------- Helpers ---------------
def verify_password(pw):
    """Verify password against stored hash (supports werkzeug and legacy sha256)."""
    if ADMIN_PASS_HASH.startswith(("pbkdf2:", "scrypt:")):
        return check_password_hash(ADMIN_PASS_HASH, pw)
    # Legacy sha256 format
    import hashlib
    return hashlib.sha256(pw.encode()).hexdigest() == ADMIN_PASS_HASH


def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            if request.is_json or request.headers.get("X-Requested-With"):
                return jsonify({"error": "unauthorized"}), 401
            return redirect(url_for("login"))
        return f(*args, **kwargs)
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
    """Run a shell command and return (returncode, stdout, stderr)."""
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
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if username == ADMIN_USER and verify_password(password):
            session["logged_in"] = True
            session["username"] = username
            return redirect(url_for("dashboard"))
        return render_template("login.html", error="Invalid credentials")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# --------------- Page Routes ---------------
@app.route("/")
@login_required
def dashboard():
    return render_template("dashboard.html")


# --------------- API Routes ---------------
@app.route("/api/ports")
@login_required
def api_ports():
    return jsonify(get_all_ports())


@app.route("/api/ports/<device>/restart", methods=["POST"])
@login_required
def api_restart_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "restart", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Restarted {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/kick", methods=["POST"])
@login_required
def api_kick_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    # Kill active sessions holding this device, clear lock/owner
    lock_file = f"/run/console-gateway.{device}.lock"
    owner_file = f"/run/console-gateway.{device}.owner"
    run_cmd(["bash", "-c",
        f"fuser /dev/{device} 2>/dev/null | xargs -r kill 2>/dev/null; "
        f"rm -f {lock_file} {owner_file}"])
    # Then restart the bridge service
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "restart", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Kicked sessions and restarted {device}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/unlock", methods=["POST"])
@login_required
def api_unlock_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    # Remove the lock and owner files, then kill any socat session holding the device
    lock_file = f"/run/console-gateway.{device}.lock"
    owner_file = f"/run/console-gateway.{device}.owner"
    # Find and kill the session handler holding this device
    rc, out, _ = run_cmd([
        "bash", "-c",
        f"fuser /dev/{device} 2>/dev/null | xargs -r kill 2>/dev/null; "
        f"rm -f {lock_file} {owner_file}"
    ])
    return jsonify({"ok": True, "message": f"Unlocked {device}"})


@app.route("/api/ports/<device>/stop", methods=["POST"])
@login_required
def api_stop_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "stop", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Stopped {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/ports/<device>/rename", methods=["POST"])
@login_required
def api_rename_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    data = request.get_json() or {}
    new_alias = data.get("alias", "").strip()
    if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}$', new_alias):
        return jsonify({"error": "Invalid alias. Use letters, digits, hyphens, underscores (1-60 chars)."}), 400

    # Update alias column in map.tsv only
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


@app.route("/api/ports/<device>/start", methods=["POST"])
@login_required
def api_start_port(device):
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400
    svc = f"console-lock-bridge@{device}.service"
    rc, out, err = run_cmd(["systemctl", "start", svc])
    if rc == 0:
        return jsonify({"ok": True, "message": f"Started {svc}"})
    return jsonify({"error": err}), 500


@app.route("/api/status")
@login_required
def api_status():
    hostname = socket.gethostname()
    # SSH
    rc_ssh, _, _ = run_cmd(["systemctl", "is-active", "--quiet", "ssh"])
    if rc_ssh != 0:
        rc_ssh, _, _ = run_cmd(["systemctl", "is-active", "--quiet", "sshd"])
    # Tailscale
    rc_ts, ts_out, _ = run_cmd(["tailscale", "status", "--json"])
    tailscale_ip = None
    if rc_ts == 0:
        try:
            ts_data = json.loads(ts_out)
            self_key = ts_data.get("Self", {})
            addrs = self_key.get("TailscaleIPs", [])
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
def api_sessions():
    n = request.args.get("n", 100, type=int)
    lines = read_session_log(min(n, 1000))
    return jsonify(lines)


@app.route("/api/detect")
@login_required
def api_detect():
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


@app.route("/api/settings/ports")
@login_required
def api_settings_ports():
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
def api_settings_port_update(device):
    """Update per-port settings."""
    if not re.match(r'^[a-zA-Z0-9_-]+$', device):
        return jsonify({"error": "invalid device name"}), 400

    data = request.get_json() or {}
    baud = data.get("baud")
    idle_timeout = data.get("idle_timeout")
    max_session = data.get("max_session")

    # Validate
    valid_bauds = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200]
    if baud is not None and int(baud) not in valid_bauds:
        return jsonify({"error": f"Invalid baud rate. Valid: {valid_bauds}"}), 400
    if idle_timeout is not None and (int(idle_timeout) < 30 or int(idle_timeout) > 86400):
        return jsonify({"error": "Idle timeout must be 30-86400 seconds"}), 400
    if max_session is not None and (int(max_session) < 60 or int(max_session) > 604800):
        return jsonify({"error": "Max session must be 60-604800 seconds"}), 400

    # Read current settings (create defaults from map if drop-in doesn't exist yet)
    current = read_port_settings(device)
    if not current:
        # Find device in map to get baseline values
        map_entry = next((p for p in read_map() if p["device"] == device), None)
        if not map_entry:
            return jsonify({"error": f"Device {device} not found in map"}), 404
        current = {
            "CONSOLE_DEV": f"/dev/{device}",
            "CONSOLE_BAUD": str(map_entry["baud"]),
            "LOCAL_CONSOLE_PORT": str(map_entry["port"]),
            "IDLE_TIMEOUT_SECONDS": "900",
            "MAX_SESSION_SECONDS": "3600",
        }

    # Update values
    if baud is not None:
        current["CONSOLE_BAUD"] = str(int(baud))
    if idle_timeout is not None:
        current["IDLE_TIMEOUT_SECONDS"] = str(int(idle_timeout))
    if max_session is not None:
        current["MAX_SESSION_SECONDS"] = str(int(max_session))

    # Also update baud in map.tsv
    if baud is not None:
        map_lines = []
        if os.path.isfile(MAP_FILE):
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

    # Write drop-in
    conf_dir = f"{DROPIN_DIR}/console-lock-bridge@{device}.service.d"
    conf_file = f"{conf_dir}/10-env.conf"
    content = "[Service]\n"
    for k, v in current.items():
        content += f"Environment={k}={v}\n"

    rc, _, err = run_cmd(["bash", "-c",
        f"mkdir -p '{conf_dir}' && cat > '{conf_file}' << 'CONFEOF'\n{content}CONFEOF"])
    if rc != 0:
        return jsonify({"error": f"Failed to write config: {err}"}), 500

    # Reload and restart
    run_cmd(["systemctl", "daemon-reload"])
    run_cmd(["systemctl", "restart", f"console-lock-bridge@{device}.service"])

    return jsonify({"ok": True, "message": f"Settings updated for {device}"})


@app.route("/api/settings/global")
@login_required
def api_settings_global():
    """Get global settings."""
    # Read from the systemd template defaults
    template = f"{DROPIN_DIR}/console-lock-bridge@.service"
    defaults = {}
    if os.path.isfile(template):
        with open(template) as f:
            for line in f:
                m = re.match(r'^Environment=(\w+)=(.+)$', line.strip())
                if m:
                    defaults[m.group(1)] = m.group(2)

    # Web service settings
    web_conf = f"{DROPIN_DIR}/{WEB_SERVICE}.service"
    web_settings = {}
    if os.path.isfile(web_conf):
        with open(web_conf) as f:
            for line in f:
                m = re.match(r'^Environment=(\w+)=(.+)$', line.strip())
                if m:
                    web_settings[m.group(1)] = m.group(2)

    # SSH config
    ssh_port = "22"
    ssh_conf = "/etc/ssh/sshd_config.d/90-console-gateway.conf"
    allow_users = ""
    if os.path.isfile(ssh_conf):
        with open(ssh_conf) as f:
            for line in f:
                if line.strip().startswith("AllowUsers"):
                    allow_users = line.strip().split(None, 1)[1] if len(line.strip().split(None, 1)) > 1 else ""

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
        "ssh": {
            "allow_users": allow_users,
        },
    })


@app.route("/api/settings/global", methods=["POST"])
@login_required
def api_settings_global_update():
    """Update global defaults in the systemd template."""
    data = request.get_json() or {}

    valid_bauds = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200]
    baud = data.get("default_baud")
    idle = data.get("idle_timeout")
    maxs = data.get("max_session")

    if baud is not None and int(baud) not in valid_bauds:
        return jsonify({"error": f"Invalid baud rate"}), 400
    if idle is not None and (int(idle) < 30 or int(idle) > 86400):
        return jsonify({"error": "Idle timeout must be 30-86400"}), 400
    if maxs is not None and (int(maxs) < 60 or int(maxs) > 604800):
        return jsonify({"error": "Max session must be 60-604800"}), 400

    # Update the template service file
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

    rc, _, err = run_cmd(["bash", "-c",
        f"cat > '{template}' << 'CONFEOF'\n{content}CONFEOF"])
    if rc != 0:
        return jsonify({"error": f"Failed: {err}"}), 500

    run_cmd(["systemctl", "daemon-reload"])
    return jsonify({"ok": True, "message": "Global defaults updated. New ports will use these values."})


# --------------- Tailscale API ---------------
@app.route("/api/tailscale/status")
@login_required
def api_tailscale_status():
    rc, out, err = run_cmd(["tailscale", "status", "--json"], timeout=10)
    if rc != 0:
        # Check if tailscaled is running at all
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
def api_tailscale_up():
    rc, out, err = run_cmd(["tailscale", "up"], timeout=15)
    combined = (out + err).strip()
    # Check if it needs browser auth
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
def api_tailscale_down():
    rc, out, err = run_cmd(["tailscale", "down"], timeout=10)
    if rc == 0:
        return jsonify({"ok": True, "message": "Tailscale disconnected"})
    return jsonify({"error": err}), 500


@app.route("/api/tailscale/ping", methods=["POST"])
@login_required
def api_tailscale_ping():
    target = request.json.get("target", "") if request.is_json else ""
    if not target or not re.match(r'^[a-zA-Z0-9._-]+$', target):
        return jsonify({"error": "invalid target"}), 400
    rc, out, err = run_cmd(["tailscale", "ping", "-c", "3", target], timeout=15)
    return jsonify({"ok": rc == 0, "output": out if rc == 0 else err})


# --------------- WebSocket Terminal ---------------
@socketio.on("connect", namespace="/terminal")
def terminal_connect():
    if not session.get("logged_in"):
        disconnect()
        return


@socketio.on("open_terminal", namespace="/terminal")
def open_terminal(data):
    if not session.get("logged_in"):
        disconnect()
        return

    port = data.get("port")
    if not port or not str(port).isdigit():
        emit("terminal_output", {"data": "[error] Invalid port\r\n"})
        return

    port = int(port)

    # Validate port is in the allowed map (prevent connecting to arbitrary local services)
    allowed_ports = {p["port"] for p in read_map()}
    if port not in allowed_ports:
        emit("terminal_output", {"data": "[error] Port not in allowed list\r\n"})
        return

    sid = request.sid

    # Close existing session if any
    if sid in terminal_sessions:
        try:
            terminal_sessions[sid].close()
        except Exception:
            pass

    import eventlet
    try:
        sock = eventlet.connect(("127.0.0.1", port))
        terminal_sessions[sid] = sock
        emit("terminal_output", {"data": f"[connected] localhost:{port}\r\n"})

        def read_loop():
            try:
                while sid in terminal_sessions:
                    data = sock.recv(4096)
                    if not data:
                        break
                    socketio.emit(
                        "terminal_output",
                        {"data": data.decode("utf-8", errors="replace")},
                        namespace="/terminal",
                        to=sid,
                    )
            except Exception:
                pass
            finally:
                socketio.emit(
                    "terminal_output",
                    {"data": "\r\n[disconnected]\r\n"},
                    namespace="/terminal",
                    to=sid,
                )
                terminal_sessions.pop(sid, None)

        eventlet.spawn(read_loop)

    except Exception as e:
        emit("terminal_output", {"data": f"[error] Cannot connect: {e}\r\n"})


@socketio.on("terminal_input", namespace="/terminal")
def terminal_input(data):
    sid = request.sid
    sock = terminal_sessions.get(sid)
    if sock:
        try:
            sock.sendall(data.get("data", "").encode("utf-8"))
        except Exception:
            pass


@socketio.on("close_terminal", namespace="/terminal")
def close_terminal():
    sid = request.sid
    sock = terminal_sessions.pop(sid, None)
    if sock:
        try:
            sock.close()
        except Exception:
            pass


@socketio.on("disconnect", namespace="/terminal")
def terminal_disconnect():
    sid = request.sid
    sock = terminal_sessions.pop(sid, None)
    if sock:
        try:
            sock.close()
        except Exception:
            pass


if __name__ == "__main__":
    print(f"Console Gateway Web - http://{LISTEN_HOST}:{LISTEN_PORT}")
    print(f"Default login: {ADMIN_USER} / consolegateway")
    socketio.run(app, host=LISTEN_HOST, port=LISTEN_PORT)
APPEOF

# ====== Write login.html ======
log "Writing templates..."
cat > "${INSTALL_DIR}/templates/login.html" <<'LOGINEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Console Gateway - Login</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    body {
      background: linear-gradient(135deg, #1C0B2E 0%, #2A1148 50%, #1C0B2E 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    }
    .login-card {
      background: rgba(77, 20, 140, 0.15);
      border: 1px solid rgba(77, 20, 140, 0.4);
      border-radius: 12px;
      padding: 2.5rem;
      width: 400px;
      backdrop-filter: blur(10px);
    }
    .login-card h4 {
      color: #FFFFFF;
      font-weight: 700;
      letter-spacing: -0.02em;
    }
    .login-card .brand-accent {
      display: block;
      width: 60px;
      height: 4px;
      background: linear-gradient(90deg, #4D148C, #7D22C3, #FF6200);
      border-radius: 2px;
      margin: 0 auto 1.5rem;
    }
    .form-control {
      background: rgba(28, 11, 46, 0.8);
      border-color: rgba(77, 20, 140, 0.5);
      color: #FFFFFF;
      border-radius: 8px;
      padding: .6rem .9rem;
    }
    .form-control:focus {
      background: rgba(28, 11, 46, 0.9);
      color: #FFFFFF;
      border-color: #007AB7;
      box-shadow: 0 0 0 .2rem rgba(0, 122, 183, .25);
    }
    .btn-primary {
      background: #4D148C;
      border-color: #4D148C;
      color: #FFFFFF;
      font-weight: 600;
      border-radius: 8px;
      padding: .6rem;
      transition: all 0.2s;
    }
    .btn-primary:hover {
      background: #7D22C3;
      border-color: #7D22C3;
      color: #FFFFFF;
    }
    label { color: #B0A0C0; font-size: 0.9rem; }
    .alert-danger { background: rgba(222, 0, 46, 0.15); border-color: #DE002E; color: #ff6b85; }
  </style>
</head>
<body>
  <div class="login-card">
    <h4 class="text-center mb-2">Console Gateway</h4>
    <span class="brand-accent"></span>
    {% if error %}
    <div class="alert alert-danger py-2">{{ error }}</div>
    {% endif %}
    <form method="POST">
      <div class="mb-3">
        <label class="form-label">Username</label>
        <input type="text" name="username" class="form-control" autofocus required>
      </div>
      <div class="mb-3">
        <label class="form-label">Password</label>
        <input type="password" name="password" class="form-control" required>
      </div>
      <button type="submit" class="btn btn-primary w-100">Login</button>
    </form>
  </div>
</body>
</html>
LOGINEOF

# ====== Write dashboard.html ======
cat > "${INSTALL_DIR}/templates/dashboard.html" <<'DASHEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Console Gateway</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css" rel="stylesheet">
  <style>
    :root {
      /* Brand Colors */
      --brand-primary: #4D148C;
      --brand-accent: #FF6200;
      --brand-blue: #007AB7;
      --brand-cyan: #0CC0DF;
      --brand-green: #008A00;
      --brand-red: #DE002E;
      --brand-yellow: #F7B118;
      --brand-highlight: #7D22C3;
      --brand-tint: #825BAF;
      /* UI Theme (dark purple) */
      --bg-dark: #1C0B2E;
      --bg-card: #2A1148;
      --border: rgba(77, 20, 140, 0.45);
      --border-strong: #4D148C;
      --accent: #FF6200;
      --text: #FFFFFF;
      --text-muted: #B0A0C0;
      --text-label: #9080A8;
    }
    body { background: var(--bg-dark); color: var(--text); font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; }
    .navbar { background: linear-gradient(90deg, #2A0E4A, #4D148C) !important; border-bottom: 2px solid var(--brand-accent); }
    .navbar-brand { color: #FFFFFF !important; font-weight: 700; letter-spacing: -0.02em; }
    .navbar-brand i { color: var(--brand-accent); }
    .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 10px; }
    .card-header { background: rgba(77, 20, 140, 0.3); border-bottom: 1px solid var(--border); font-weight: 600; color: #fff; }
    .table { color: var(--text); --bs-table-bg: transparent; }
    .table thead th { border-color: var(--border); color: var(--text-label); font-size: .85rem; text-transform: uppercase; letter-spacing: 0.03em; }
    .table td { border-color: var(--border); vertical-align: middle; color: #E0D8EC; }
    .table code { color: var(--brand-cyan); background: rgba(12, 192, 223, .1); padding: 2px 6px; border-radius: 4px; }

    .badge-running { background: var(--brand-green); color: #fff; }
    .badge-stopped { background: #565656; color: #fff; }
    .badge-busy { background: var(--brand-yellow); color: #1C0B2E; }
    .badge-no-device { background: var(--brand-red); color: #fff; }

    .status-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
    .status-dot.ok { background: var(--brand-green); }
    .status-dot.down { background: var(--brand-red); }

    .text-muted { color: var(--text-muted) !important; }

    .btn-sm { font-size: .8rem; }
    .btn-primary { background: var(--brand-primary); border-color: var(--brand-primary); color: #fff; }
    .btn-primary:hover { background: var(--brand-highlight); border-color: var(--brand-highlight); color: #fff; }
    .btn-outline-light { border-color: var(--border-strong); color: var(--text-muted); }
    .btn-outline-light:hover { background: rgba(77, 20, 140, 0.5); color: #fff; border-color: var(--brand-highlight); }
    .btn-outline-danger { border-color: var(--brand-red); color: #ff6b85; }
    .btn-outline-danger:hover { background: var(--brand-red); color: #fff; }

    /* Terminal */
    #terminal-panel { display: none; }
    #terminal-panel.active { display: block; }
    #terminal-container { height: 420px; background: #0a0516; border-radius: 6px; overflow: hidden; }
    .terminal-header { background: #1a0a30; padding: 8px 16px; border-radius: 6px 6px 0 0; display: flex; justify-content: space-between; align-items: center; }
    .terminal-header .title { color: var(--brand-green); font-family: monospace; }

    /* Session log */
    #session-log { max-height: 300px; overflow-y: auto; background: rgba(28, 11, 46, 0.8); border-radius: 6px; padding: 12px; font-family: monospace; font-size: .85rem; color: #d0c8e0; }
    #session-log .line { padding: 2px 0; }

    /* Tabs */
    .nav-tabs { border-color: var(--border); }
    .nav-tabs .nav-link { color: var(--text-muted); border: none; transition: color 0.2s; }
    .nav-tabs .nav-link.active { background: var(--bg-card); color: var(--brand-accent); border-bottom: 2px solid var(--brand-accent); }
    .nav-tabs .nav-link:hover { color: #fff; }

    .info-value { font-size: 1.1rem; font-weight: 600; color: #fff; }

    /* Status cards */
    .card .small { color: var(--text-label); }

    /* Scrollbar */
    ::-webkit-scrollbar { width: 6px; }
    ::-webkit-scrollbar-track { background: var(--bg-dark); }
    ::-webkit-scrollbar-thumb { background: var(--brand-primary); border-radius: 3px; }

    /* Toast */
    .toast { border: 1px solid var(--border-strong) !important; }

    /* Forms in dark theme */
    .form-select, .form-control { transition: border-color 0.2s; }
    .form-select:focus, .form-control:focus { border-color: var(--brand-blue) !important; box-shadow: 0 0 0 .2rem rgba(0, 122, 183, .25); }
  </style>
</head>
<body>
  <nav class="navbar navbar-dark px-3">
    <span class="navbar-brand"><i class="bi bi-hdd-rack"></i> Console Gateway <span style="font-size:.65em;font-weight:400;color:var(--brand-tint);vertical-align:middle;">v2.9</span></span>
    <div class="d-flex align-items-center gap-3">
      <span class="text-muted small" id="sys-time"></span>
      <span class="text-muted small" id="sys-host"></span>
      <a href="/logout" class="btn btn-sm btn-outline-light"><i class="bi bi-box-arrow-right"></i> Logout</a>
    </div>
  </nav>

  <div class="container-fluid p-3">
    <!-- Status Bar -->
    <div class="row mb-3">
      <div class="col-md-3">
        <div class="card p-3">
          <div class="text-muted small">Ports</div>
          <div class="info-value" id="stat-total">-</div>
        </div>
      </div>
      <div class="col-md-3">
        <div class="card p-3">
          <div class="text-muted small">Running</div>
          <div class="info-value text-success" id="stat-running">-</div>
        </div>
      </div>
      <div class="col-md-3">
        <div class="card p-3">
          <div class="text-muted small">SSH</div>
          <div class="info-value" id="stat-ssh">-</div>
        </div>
      </div>
      <div class="col-md-3">
        <div class="card p-3">
          <div class="text-muted small">Tailscale</div>
          <div class="info-value" id="stat-tailscale">-</div>
        </div>
      </div>
    </div>

    <!-- Tabs -->
    <ul class="nav nav-tabs mb-3" id="mainTabs">
      <li class="nav-item">
        <a class="nav-link active" data-bs-toggle="tab" href="#tab-ports"><i class="bi bi-list-ul"></i> Ports</a>
      </li>
      <li class="nav-item">
        <a class="nav-link" data-bs-toggle="tab" href="#tab-terminal"><i class="bi bi-terminal"></i> Terminal</a>
      </li>
      <li class="nav-item">
        <a class="nav-link" data-bs-toggle="tab" href="#tab-tailscale"><i class="bi bi-globe2"></i> Tailscale</a>
      </li>
      <li class="nav-item">
        <a class="nav-link" data-bs-toggle="tab" href="#tab-logs"><i class="bi bi-journal-text"></i> Session Log</a>
      </li>
      <li class="nav-item">
        <a class="nav-link" data-bs-toggle="tab" href="#tab-settings"><i class="bi bi-gear"></i> Settings</a>
      </li>
    </ul>

    <div class="tab-content">
      <!-- Ports Tab -->
      <div class="tab-pane fade show active" id="tab-ports">
        <div class="card">
          <div class="card-header d-flex justify-content-between align-items-center">
            <span><i class="bi bi-hdd-stack"></i> Port Map</span>
            <button class="btn btn-sm btn-outline-light" onclick="refreshPorts()"><i class="bi bi-arrow-clockwise"></i> Refresh</button>
          </div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <thead>
                <tr>
                  <th>Device</th>
                  <th>Port</th>
                  <th>Baud</th>
                  <th>Alias</th>
                  <th>Status</th>
                  <th>Link</th>
                  <th>Owner</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody id="ports-table"></tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Terminal Tab -->
      <div class="tab-pane fade" id="tab-terminal">
        <div class="card">
          <div class="card-header d-flex justify-content-between align-items-center">
            <span><i class="bi bi-terminal"></i> Web Terminal</span>
            <div class="d-flex align-items-center gap-2">
              <select id="term-port-select" class="form-select form-select-sm" style="width:auto; background:var(--bg-dark); color:var(--text); border-color:var(--border);">
                <option value="">-- Select Port --</option>
              </select>
              <button class="btn btn-sm btn-outline-light" id="btn-connect" onclick="connectTerminal()"><i class="bi bi-plug"></i> Connect</button>
              <button class="btn btn-sm btn-outline-danger" id="btn-disconnect" onclick="disconnectTerminal()" style="display:none"><i class="bi bi-x-circle"></i> Disconnect</button>
            </div>
          </div>
          <div class="card-body p-2">
            <div id="terminal-container"></div>
          </div>
        </div>
      </div>

      <!-- Tailscale Tab -->
      <div class="tab-pane fade" id="tab-tailscale">
        <div class="row mb-3">
          <!-- This Node -->
          <div class="col-md-5">
            <div class="card">
              <div class="card-header d-flex justify-content-between align-items-center">
                <span><i class="bi bi-pc-display"></i> This Node</span>
                <div class="d-flex gap-2">
                  <button class="btn btn-sm btn-outline-light" onclick="refreshTailscale()"><i class="bi bi-arrow-clockwise"></i></button>
                </div>
              </div>
              <div class="card-body">
                <div id="ts-not-running" style="display:none">
                  <div class="text-center py-3">
                    <i class="bi bi-exclamation-triangle text-warning" style="font-size:2rem"></i>
                    <p class="mt-2 mb-3" id="ts-not-running-msg">Tailscale is not connected</p>
                    <button class="btn btn-sm btn-primary" onclick="tailscaleUp()"><i class="bi bi-power"></i> Connect</button>
                  </div>
                </div>
                <div id="ts-auth-needed" style="display:none">
                  <div class="text-center py-3">
                    <i class="bi bi-key text-warning" style="font-size:2rem"></i>
                    <p class="mt-2">Authentication required</p>
                    <div id="ts-auth-qr" class="my-3 d-flex justify-content-center"></div>
                    <p class="small text-muted">Scan QR code with your phone, or click below:</p>
                    <a id="ts-auth-url" href="#" target="_blank" class="btn btn-sm btn-primary mb-2"><i class="bi bi-box-arrow-up-right"></i> Open Auth Page</a>
                    <p class="small text-muted mt-2">After authenticating, click Refresh</p>
                  </div>
                </div>
                <div id="ts-connected" style="display:none">
                  <table class="table table-sm mb-0">
                    <tr><td class="text-muted" style="width:120px">Status</td><td><span class="badge badge-running" id="ts-state">-</span></td></tr>
                    <tr><td class="text-muted">Hostname</td><td id="ts-hostname">-</td></tr>
                    <tr><td class="text-muted">Tailscale IP</td><td><code id="ts-ip">-</code></td></tr>
                    <tr><td class="text-muted">DNS Name</td><td><small id="ts-dns">-</small></td></tr>
                    <tr><td class="text-muted">Tailnet</td><td><small id="ts-tailnet">-</small></td></tr>
                    <tr><td class="text-muted">OS</td><td id="ts-os">-</td></tr>
                  </table>
                  <div class="mt-3 d-flex gap-2">
                    <button class="btn btn-sm btn-outline-danger" onclick="tailscaleDown()"><i class="bi bi-power"></i> Disconnect</button>
                  </div>
                </div>
              </div>
            </div>
          </div>
          <!-- Peers -->
          <div class="col-md-7">
            <div class="card">
              <div class="card-header">
                <span><i class="bi bi-diagram-3"></i> Peers</span>
                <span class="badge bg-secondary ms-2" id="ts-peer-count">0</span>
              </div>
              <div class="card-body p-0">
                <div id="ts-peers-empty" class="text-center text-muted py-4">No peers</div>
                <table class="table table-sm table-hover mb-0" id="ts-peers-table" style="display:none">
                  <thead>
                    <tr>
                      <th></th>
                      <th>Hostname</th>
                      <th>IP</th>
                      <th>OS</th>
                      <th>Status</th>
                      <th>Action</th>
                    </tr>
                  </thead>
                  <tbody id="ts-peers-body"></tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
        <!-- Ping result -->
        <div class="card" id="ts-ping-card" style="display:none">
          <div class="card-header"><i class="bi bi-speedometer2"></i> Ping Result</div>
          <div class="card-body">
            <pre id="ts-ping-output" style="color:#c5c8ca; background:#111a24; padding:12px; border-radius:6px; margin:0; white-space:pre-wrap;"></pre>
          </div>
        </div>
      </div>

      <!-- Logs Tab -->
      <div class="tab-pane fade" id="tab-logs">
        <div class="card">
          <div class="card-header d-flex justify-content-between align-items-center">
            <span><i class="bi bi-journal-text"></i> Session Log</span>
            <button class="btn btn-sm btn-outline-light" onclick="refreshLogs()"><i class="bi bi-arrow-clockwise"></i> Refresh</button>
          </div>
          <div class="card-body">
            <div id="session-log"><span class="text-muted">Loading...</span></div>
          </div>
        </div>
      </div>

      <!-- Settings Tab -->
      <div class="tab-pane fade" id="tab-settings">
        <div class="row">
          <!-- Per-Port Settings -->
          <div class="col-md-8">
            <div class="card mb-3">
              <div class="card-header d-flex justify-content-between align-items-center">
                <span><i class="bi bi-sliders"></i> Port Settings</span>
                <button class="btn btn-sm btn-outline-light" onclick="refreshSettings()"><i class="bi bi-arrow-clockwise"></i></button>
              </div>
              <div class="card-body p-0">
                <table class="table table-sm table-hover mb-0">
                  <thead>
                    <tr>
                      <th>Device</th>
                      <th>Alias</th>
                      <th>TCP Port</th>
                      <th>Baud Rate</th>
                      <th>Idle Timeout (s)</th>
                      <th>Max Session (s)</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody id="settings-ports-table"></tbody>
                </table>
              </div>
            </div>
          </div>
          <!-- Global & Web Settings -->
          <div class="col-md-4">
            <div class="card mb-3">
              <div class="card-header"><i class="bi bi-globe2"></i> Global Defaults</div>
              <div class="card-body">
                <div class="mb-2">
                  <label class="form-label small text-muted">Default Baud Rate</label>
                  <select id="set-global-baud" class="form-select form-select-sm" style="background:var(--bg-dark); color:var(--text); border-color:var(--border-strong);">
                    <option value="9600">9600</option><option value="19200">19200</option>
                    <option value="38400">38400</option><option value="57600">57600</option>
                    <option value="115200">115200</option>
                  </select>
                </div>
                <div class="mb-2">
                  <label class="form-label small text-muted">Default Idle Timeout (s)</label>
                  <input type="number" id="set-global-idle" class="form-control form-control-sm" style="background:var(--bg-dark); color:var(--text); border-color:var(--border-strong);" min="30" max="86400">
                </div>
                <div class="mb-2">
                  <label class="form-label small text-muted">Default Max Session (s)</label>
                  <input type="number" id="set-global-maxs" class="form-control form-control-sm" style="background:var(--bg-dark); color:var(--text); border-color:var(--border-strong);" min="60" max="604800">
                </div>
                <button class="btn btn-sm btn-primary w-100" onclick="saveGlobalSettings()">Save Defaults</button>
                <small class="text-muted d-block mt-1">Applies to ports without per-port overrides</small>
                <div id="global-save-msg" class="small mt-2" style="display:none"></div>
              </div>
            </div>
            <div class="card mb-3">
              <div class="card-header"><i class="bi bi-window-desktop"></i> Web Service</div>
              <div class="card-body">
                <table class="table table-sm mb-0">
                  <tr><td class="text-muted">Listen</td><td id="set-web-host">-</td></tr>
                  <tr><td class="text-muted">Port</td><td id="set-web-port">-</td></tr>
                  <tr><td class="text-muted">Admin User</td><td id="set-web-user">-</td></tr>
                </table>
                <small class="text-muted d-block mt-2">Edit via: sudo systemctl edit console-gateway-web</small>
              </div>
            </div>
            <div class="card">
              <div class="card-header"><i class="bi bi-shield-lock"></i> SSH</div>
              <div class="card-body">
                <table class="table table-sm mb-0">
                  <tr><td class="text-muted">AllowUsers</td><td id="set-ssh-users">-</td></tr>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Rename Modal -->
  <div class="modal fade" id="renameModal" tabindex="-1">
    <div class="modal-dialog modal-dialog-centered">
      <div class="modal-content" style="background:var(--bg-card); border:1px solid var(--border-strong); color:var(--text);">
        <div class="modal-header" style="border-color:var(--border);">
          <h6 class="modal-title"><i class="bi bi-pencil-square" style="color:var(--brand-accent)"></i> Edit Alias</h6>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
        </div>
        <div class="modal-body">
          <p class="small text-muted">Device: <code id="rename-old"></code></p>
          <label class="form-label small" style="color:var(--text-muted)">Alias</label>
          <input type="text" id="rename-input" class="form-control" style="background:var(--bg-dark); color:var(--text); border-color:var(--border-strong);" placeholder="e.g. SW-CORE-01" maxlength="60" pattern="[a-zA-Z0-9][a-zA-Z0-9_-]*">
          <small class="text-muted">Letters, digits, hyphens, underscores. Max 60 chars.</small>
          <div id="rename-error" class="text-danger small mt-2" style="display:none"></div>
        </div>
        <div class="modal-footer" style="border-color:var(--border);">
          <button type="button" class="btn btn-sm btn-outline-light" data-bs-dismiss="modal">Cancel</button>
          <button type="button" class="btn btn-sm btn-primary" onclick="submitRename()" id="rename-submit-btn">Rename</button>
        </div>
      </div>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/socket.io-client@4/dist/socket.io.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js"></script>
  <script>
    // ---- State ----
    let term = null;
    let socket = null;
    let connected = false;

    // ---- API helpers ----
    async function api(url, method = 'GET', body = null) {
      const opts = { method, headers: { 'X-Requested-With': 'XMLHttpRequest' } };
      if (body) {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
      }
      const r = await fetch(url, opts);
      if (r.status === 401) { window.location = '/login'; return null; }
      return r.json();
    }

    // ---- Dashboard ----
    async function refreshStatus() {
      const s = await api('/api/status');
      if (!s) return;
      document.getElementById('sys-time').textContent = s.time;
      document.getElementById('sys-host').textContent = s.hostname;
      document.getElementById('stat-ssh').innerHTML = statusHtml(s.ssh);
      const tsText = s.tailscale === 'ok' ? (s.tailscale_ip || 'OK') : 'Not Connected';
      document.getElementById('stat-tailscale').innerHTML =
        `<span class="status-dot ${s.tailscale === 'ok' ? 'ok' : 'down'}"></span>${tsText}`;
    }

    function statusHtml(s) {
      return `<span class="status-dot ${s === 'ok' ? 'ok' : 'down'}"></span>${s === 'ok' ? 'OK' : 'Down'}`;
    }

    async function refreshPorts() {
      const ports = await api('/api/ports');
      if (!ports) return;
      const tbody = document.getElementById('ports-table');
      const sel = document.getElementById('term-port-select');
      const curVal = sel.value;
      tbody.innerHTML = '';
      sel.innerHTML = '<option value="">-- Select Port --</option>';

      let total = 0, running = 0;
      ports.forEach(p => {
        total++;
        if (p.status === 'running' || p.status === 'busy') running++;

        const badgeClass = `badge-${p.status}`;
        const actions = buildActions(p);

        tbody.innerHTML += `
          <tr>
            <td><code>${p.device}</code></td>
            <td>${p.port}</td>
            <td>${p.baud}</td>
            <td>${p.alias || '-'}</td>
            <td><span class="badge ${badgeClass}">${p.status}</span></td>
            <td><small class="text-muted">${p.link_target || ''}</small></td>
            <td><small>${p.owner || '-'}</small></td>
            <td>${actions}</td>
          </tr>`;

        if (p.status === 'running' || p.status === 'busy') {
          sel.innerHTML += `<option value="${p.port}" ${String(p.port) === curVal ? 'selected' : ''}>${p.alias || p.device} (:${p.port})</option>`;
        }
      });

      document.getElementById('stat-total').textContent = total;
      document.getElementById('stat-running').textContent = running;
    }

    function buildActions(p) {
      let html = '';
      html += `<button class="btn btn-sm btn-outline-light me-1" onclick="showRename('${p.device}','${p.alias || ''}')" title="Edit Alias"><i class="bi bi-pencil"></i></button>`;
      if (p.status === 'running') {
        html += `<button class="btn btn-sm btn-outline-light me-1" onclick="portAction('${p.device}','restart')" title="Restart"><i class="bi bi-arrow-repeat"></i></button>`;
        html += `<button class="btn btn-sm btn-outline-light me-1" onclick="portAction('${p.device}','stop')" title="Stop"><i class="bi bi-stop-circle"></i></button>`;
        html += `<button class="btn btn-sm btn-outline-light" onclick="openTerminal('${p.port}')" title="Connect"><i class="bi bi-terminal"></i></button>`;
      } else if (p.status === 'busy') {
        html += `<button class="btn btn-sm btn-outline-danger me-1" onclick="portAction('${p.device}','unlock')" title="Unlock"><i class="bi bi-unlock"></i></button>`;
        html += `<button class="btn btn-sm btn-outline-light me-1" onclick="portAction('${p.device}','kick')" title="Kick & Restart"><i class="bi bi-person-x"></i></button>`;
        html += `<button class="btn btn-sm btn-outline-light" onclick="portAction('${p.device}','restart')" title="Restart"><i class="bi bi-arrow-repeat"></i></button>`;
      } else if (p.status === 'stopped' || p.status === 'no-device') {
        html += `<button class="btn btn-sm btn-outline-light" onclick="portAction('${p.device}','start')" title="Start"><i class="bi bi-play-circle"></i></button>`;
      }
      return html;
    }

    async function portAction(device, action) {
      const r = await api(`/api/ports/${device}/${action}`, 'POST');
      if (r && r.ok) {
        setTimeout(refreshPorts, 500);
      } else if (r) {
        alert(r.error || 'Failed');
      }
    }

    // ---- Rename ----
    let renameDevice = '';
    function showRename(device, currentAlias) {
      renameDevice = device;
      document.getElementById('rename-old').textContent = device;
      document.getElementById('rename-input').value = currentAlias || '';
      document.getElementById('rename-error').style.display = 'none';
      new bootstrap.Modal(document.getElementById('renameModal')).show();
      setTimeout(() => {
        const input = document.getElementById('rename-input');
        input.focus();
        input.select();
      }, 300);
    }

    async function submitRename() {
      const newAlias = document.getElementById('rename-input').value.trim();
      if (!newAlias || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}$/.test(newAlias)) {
        const err = document.getElementById('rename-error');
        err.textContent = 'Invalid name. Use letters, digits, hyphens, underscores.';
        err.style.display = '';
        return;
      }
      const btn = document.getElementById('rename-submit-btn');
      btn.disabled = true;
      btn.textContent = 'Renaming...';

      const r = await fetch(`/api/ports/${renameDevice}/rename`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify({ alias: newAlias }),
      });
      const d = await r.json();
      btn.disabled = false;
      btn.textContent = 'Rename';

      if (d.ok) {
        bootstrap.Modal.getInstance(document.getElementById('renameModal')).hide();
        setTimeout(refreshPorts, 500);
      } else {
        const err = document.getElementById('rename-error');
        err.textContent = d.error || 'Rename failed';
        err.style.display = '';
      }
    }

    // Submit rename on Enter key
    document.getElementById('rename-input').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') submitRename();
    });

    // ---- Terminal ----
    function initTerminal() {
      if (term) return;
      term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
        theme: { background: '#0a0516', foreground: '#E0D8EC', cursor: '#FF6200' },
      });
      const fitAddon = new FitAddon.FitAddon();
      term.loadAddon(fitAddon);
      term.open(document.getElementById('terminal-container'));
      fitAddon.fit();
      window.addEventListener('resize', () => fitAddon.fit());

      // Tab switch refit
      document.querySelector('a[href="#tab-terminal"]').addEventListener('shown.bs.tab', () => {
        setTimeout(() => fitAddon.fit(), 50);
      });
    }

    function connectTerminal() {
      const port = document.getElementById('term-port-select').value;
      if (!port) { alert('Please select a port'); return; }
      initTerminal();
      term.clear();
      term.writeln('Connecting to port ' + port + '...');

      if (socket) { socket.disconnect(); }
      socket = io('/terminal');

      socket.on('connect', () => {
        socket.emit('open_terminal', { port: parseInt(port) });
        connected = true;
        document.getElementById('btn-connect').style.display = 'none';
        document.getElementById('btn-disconnect').style.display = '';
      });

      socket.on('terminal_output', (data) => {
        term.write(data.data);
      });

      socket.on('disconnect', () => {
        connected = false;
        document.getElementById('btn-connect').style.display = '';
        document.getElementById('btn-disconnect').style.display = 'none';
      });

      term.onData((data) => {
        if (connected) {
          socket.emit('terminal_input', { data: data });
        }
      });
    }

    function disconnectTerminal() {
      if (socket) {
        socket.emit('close_terminal');
        socket.disconnect();
        socket = null;
      }
      connected = false;
      document.getElementById('btn-connect').style.display = '';
      document.getElementById('btn-disconnect').style.display = 'none';
      if (term) term.writeln('\r\n[disconnected]');
    }

    function openTerminal(port) {
      // Switch to terminal tab and connect
      document.getElementById('term-port-select').value = String(port);
      const tabEl = document.querySelector('a[href="#tab-terminal"]');
      new bootstrap.Tab(tabEl).show();
      setTimeout(connectTerminal, 200);
    }

    // ---- Logs ----
    async function refreshLogs() {
      const lines = await api('/api/sessions');
      if (!lines) return;
      const el = document.getElementById('session-log');
      if (lines.length === 0) {
        el.innerHTML = '<span class="text-muted">(no sessions yet)</span>';
        return;
      }
      el.innerHTML = lines.map(l => `<div class="line">${escapeHtml(l)}</div>`).join('');
      el.scrollTop = el.scrollHeight;
    }

    function escapeHtml(s) {
      const d = document.createElement('div');
      d.textContent = s;
      return d.innerHTML;
    }

    // ---- QR Code helper ----
    function showAuthQR(url) {
      const container = document.getElementById('ts-auth-qr');
      container.innerHTML = '';
      if (!url) return;
      const qr = qrcode(0, 'M');
      qr.addData(url);
      qr.make();
      const img = document.createElement('img');
      img.src = qr.createDataURL(6, 8);
      img.style.borderRadius = '8px';
      img.style.border = '4px solid #fff';
      container.appendChild(img);
    }

    // ---- Tailscale ----
    async function refreshTailscale() {
      const d = await api('/api/tailscale/status');
      if (!d) return;

      const notRunning = document.getElementById('ts-not-running');
      const authNeeded = document.getElementById('ts-auth-needed');
      const connected = document.getElementById('ts-connected');
      const peersEmpty = document.getElementById('ts-peers-empty');
      const peersTable = document.getElementById('ts-peers-table');

      notRunning.style.display = 'none';
      authNeeded.style.display = 'none';
      connected.style.display = 'none';

      if (!d.daemon_running) {
        notRunning.style.display = '';
        document.getElementById('ts-not-running-msg').textContent = 'Tailscale daemon is not running';
        peersEmpty.style.display = '';
        peersTable.style.display = 'none';
        return;
      }

      if (d.state === 'NeedsLogin' || d.state === 'needs_login') {
        if (d.auth_url) {
          authNeeded.style.display = '';
          const link = document.getElementById('ts-auth-url');
          link.href = d.auth_url;
          showAuthQR(d.auth_url);
        } else {
          notRunning.style.display = '';
          document.getElementById('ts-not-running-msg').textContent = 'Tailscale needs login';
        }
        peersEmpty.style.display = '';
        peersTable.style.display = 'none';
        return;
      }

      if (d.state === 'Running' && d.self) {
        connected.style.display = '';
        document.getElementById('ts-state').textContent = d.state;
        document.getElementById('ts-hostname').textContent = d.self.hostname;
        document.getElementById('ts-ip').textContent = (d.self.ips || []).join(', ') || '-';
        document.getElementById('ts-dns').textContent = d.self.dns_name || '-';
        document.getElementById('ts-tailnet').textContent = d.self.tailnet || '-';
        document.getElementById('ts-os').textContent = d.self.os || '-';

        // Peers
        const peers = d.peers || {};
        const peerList = Object.values(peers);
        document.getElementById('ts-peer-count').textContent = peerList.length;

        if (peerList.length === 0) {
          peersEmpty.style.display = '';
          peersTable.style.display = 'none';
        } else {
          peersEmpty.style.display = 'none';
          peersTable.style.display = '';
          const tbody = document.getElementById('ts-peers-body');
          tbody.innerHTML = '';
          peerList.forEach(p => {
            const online = p.online;
            const dotClass = online ? 'ok' : 'down';
            const statusText = online ? 'Online' : 'Offline';
            const ip = (p.ips || [])[0] || '-';
            const pingTarget = p.ips && p.ips[0] ? p.ips[0] : p.hostname;
            tbody.innerHTML += `
              <tr>
                <td><span class="status-dot ${dotClass}"></span></td>
                <td>${escapeHtml(p.hostname)}<br><small class="text-muted">${escapeHtml(p.dns_name || '')}</small></td>
                <td><code>${escapeHtml(ip)}</code></td>
                <td>${escapeHtml(p.os)}</td>
                <td><small>${statusText}</small></td>
                <td>${online ? `<button class="btn btn-sm btn-outline-light" onclick="tailscalePing('${escapeHtml(pingTarget)}')" title="Ping"><i class="bi bi-speedometer2"></i></button>` : ''}</td>
              </tr>`;
          });
        }
      } else {
        notRunning.style.display = '';
        document.getElementById('ts-not-running-msg').textContent = 'Tailscale state: ' + (d.state || 'Unknown');
        peersEmpty.style.display = '';
        peersTable.style.display = 'none';
      }
    }

    async function tailscaleUp() {
      const notRunning = document.getElementById('ts-not-running');
      const authNeeded = document.getElementById('ts-auth-needed');
      notRunning.style.display = 'none';

      const r = await api('/api/tailscale/up', 'POST');
      if (!r) return;
      if (r.needs_auth && r.auth_url) {
        authNeeded.style.display = '';
        const link = document.getElementById('ts-auth-url');
        link.href = r.auth_url;
        link.textContent = 'Open Auth Page';
        showAuthQR(r.auth_url);
      } else {
        setTimeout(refreshTailscale, 2000);
      }
    }

    async function tailscaleDown() {
      if (!confirm('Disconnect Tailscale?')) return;
      await api('/api/tailscale/down', 'POST');
      setTimeout(refreshTailscale, 1000);
    }

    async function tailscalePing(target) {
      const card = document.getElementById('ts-ping-card');
      const output = document.getElementById('ts-ping-output');
      card.style.display = '';
      output.textContent = 'Pinging ' + target + '...';
      const r = await fetch('/api/tailscale/ping', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify({ target }),
      });
      const d = await r.json();
      output.textContent = d.output || d.error || 'No response';
    }

    // Load tailscale on tab switch
    document.querySelector('a[href="#tab-tailscale"]').addEventListener('shown.bs.tab', () => {
      refreshTailscale();
    });

    // ---- Settings ----
    const BAUD_OPTIONS = [9600, 19200, 38400, 57600, 115200];

    async function refreshSettings() {
      const [ports, global] = await Promise.all([
        api('/api/settings/ports'),
        api('/api/settings/global'),
      ]);
      if (ports) {
        const tbody = document.getElementById('settings-ports-table');
        tbody.innerHTML = '';
        ports.forEach(p => {
          const baudOpts = BAUD_OPTIONS.map(b =>
            `<option value="${b}" ${b === p.baud ? 'selected' : ''}>${b}</option>`
          ).join('');
          tbody.innerHTML += `
            <tr>
              <td>${escapeHtml(p.device)}</td>
              <td>${escapeHtml(p.alias || '-')}</td>
              <td>${p.port}</td>
              <td><select class="form-select form-select-sm" id="sp-baud-${p.device}"
                    style="background:var(--bg-dark);color:var(--text);border-color:var(--border);width:auto">${baudOpts}</select></td>
              <td><input type="number" class="form-control form-control-sm" id="sp-idle-${p.device}"
                    style="background:var(--bg-dark);color:var(--text);border-color:var(--border);width:90px"
                    value="${p.idle_timeout}" min="30" max="86400"></td>
              <td><input type="number" class="form-control form-control-sm" id="sp-maxs-${p.device}"
                    style="background:var(--bg-dark);color:var(--text);border-color:var(--border);width:90px"
                    value="${p.max_session}" min="60" max="604800"></td>
              <td><button class="btn btn-sm btn-outline-light" onclick="savePortSettings('${escapeHtml(p.device)}')"><i class="bi bi-check-lg"></i></button></td>
            </tr>`;
        });
      }
      if (global) {
        const c = global.console || {};
        const w = global.web || {};
        const s = global.ssh || {};
        document.getElementById('set-global-baud').value = c.default_baud || 9600;
        document.getElementById('set-global-idle').value = c.idle_timeout || 900;
        document.getElementById('set-global-maxs').value = c.max_session || 3600;
        document.getElementById('set-web-host').textContent = w.host || '-';
        document.getElementById('set-web-port').textContent = w.port || '-';
        document.getElementById('set-web-user').textContent = w.admin_user || '-';
        document.getElementById('set-ssh-users').textContent = s.allow_users || '-';
      }
    }

    async function savePortSettings(device) {
      const baud = parseInt(document.getElementById('sp-baud-' + device).value);
      const idle = parseInt(document.getElementById('sp-idle-' + device).value);
      const maxs = parseInt(document.getElementById('sp-maxs-' + device).value);
      const r = await api('/api/settings/ports/' + device, 'POST', { baud, idle_timeout: idle, max_session: maxs });
      if (r && r.ok) {
        showToast('Settings saved for ' + device);
      }
    }

    async function saveGlobalSettings() {
      const baud = parseInt(document.getElementById('set-global-baud').value);
      const idle = parseInt(document.getElementById('set-global-idle').value);
      const maxs = parseInt(document.getElementById('set-global-maxs').value);
      const msg = document.getElementById('global-save-msg');
      const r = await api('/api/settings/global', 'POST', { default_baud: baud, idle_timeout: idle, max_session: maxs });
      if (r && r.ok) {
        msg.textContent = 'Saved!';
        msg.className = 'small mt-2 text-success';
        msg.style.display = '';
        setTimeout(() => msg.style.display = 'none', 3000);
      } else {
        msg.textContent = 'Save failed';
        msg.className = 'small mt-2 text-danger';
        msg.style.display = '';
      }
    }

    function showToast(message) {
      const el = document.createElement('div');
      el.className = 'position-fixed bottom-0 end-0 p-3';
      el.style.zIndex = 9999;
      el.innerHTML = `<div class="toast show text-light" style="background:var(--bg-card);border:1px solid var(--brand-primary)"><div class="toast-body"><i class="bi bi-check-circle" style="color:var(--brand-green)"></i> ${escapeHtml(message)}</div></div>`;
      document.body.appendChild(el);
      setTimeout(() => el.remove(), 3000);
    }

    document.querySelector('a[href="#tab-settings"]').addEventListener('shown.bs.tab', () => {
      refreshSettings();
    });

    // ---- Init ----
    refreshStatus();
    refreshPorts();
    refreshLogs();
    setInterval(refreshStatus, 15000);
    setInterval(refreshPorts, 10000);
  </script>
</body>
</html>
DASHEOF

# ====== Create Python venv ======
log "Setting up Python virtual environment..."
if [[ ! -d "${INSTALL_DIR}/venv" ]]; then
  python3 -m venv "${INSTALL_DIR}/venv"
fi
"${INSTALL_DIR}/venv/bin/pip" install --quiet flask flask-socketio eventlet pyserial

# ====== Compute password hash (werkzeug, with salt) ======
log "Generating password hash..."
PASS_HASH=$("${INSTALL_DIR}/venv/bin/python" -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('${CGW_ADMIN_PASS}'))")

# ====== Create systemd service ======
log "Installing systemd service..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Console Gateway Web Management
After=network.target console-lock-bridge@.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=CGW_HOST=${CGW_HOST}
Environment=CGW_PORT=${CGW_PORT}
Environment=CGW_ADMIN_USER=${CGW_ADMIN_USER}
Environment=CGW_ADMIN_PASS_HASH=${PASS_HASH}
Environment=CGW_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
ExecStart=${INSTALL_DIR}/venv/bin/python app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ====== Create uninstall script ======
cat > "${INSTALL_DIR}/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${EUID}" -eq 0 ]] || { echo "sudo required"; exit 1; }
read -rp "Uninstall Console Gateway Web? (yes/N): " a
[[ "\$a" == "yes" ]] || exit 0
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
systemctl disable ${SERVICE_NAME} 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload
rm -rf ${INSTALL_DIR}
echo "Console Gateway Web uninstalled."
EOF
chmod +x "${INSTALL_DIR}/uninstall.sh"

# ====== Enable and start ======
log "Starting service..."
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}
sleep 2

# ====== Verify ======
if systemctl is-active --quiet ${SERVICE_NAME}; then
  log "Service is running."
else
  log "WARNING: Service failed to start. Check: journalctl -u ${SERVICE_NAME}"
fi

# ====== Done ======
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TS_IP=$(tailscale ip -4 2>/dev/null || true)

cat <<NOTES

============================================
  Console Gateway Web - Installed
============================================

  URL:       http://${LOCAL_IP:-localhost}:${CGW_PORT}
${TS_IP:+  Tailscale: http://${TS_IP}:${CGW_PORT}}
  Login:     ${CGW_ADMIN_USER} / (password set during install)
  Install:   ${INSTALL_DIR}

  Service:   sudo systemctl {start|stop|restart|status} ${SERVICE_NAME}
  Uninstall: sudo ${INSTALL_DIR}/uninstall.sh

  Change password:
    NEW_HASH=\$(${INSTALL_DIR}/venv/bin/python -c \\
      "from werkzeug.security import generate_password_hash; \\
       print(generate_password_hash(input('New password: ')))")
    sudo systemctl edit ${SERVICE_NAME}
    # Set: Environment=CGW_ADMIN_PASS_HASH=\$NEW_HASH
    sudo systemctl restart ${SERVICE_NAME}

============================================
NOTES
