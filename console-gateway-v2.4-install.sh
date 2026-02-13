#!/usr/bin/env bash
# Console Gateway v2.4 - Multi-port Exclusive Console Server (Tailscale + SSH + socat+flock)
# Improvements over v2.3:
#   - Extracted socat session handler to standalone script (no nested quote hell)
#   - Strict map.tsv field validation on read/write
#   - Fixed systemctl glob restart (explicit unit iteration)
#   - consolectl rescan now creates drop-ins and starts new units
#   - Added logrotate config
#   - Added flock on map.tsv writes to prevent corruption
#   - console helper now checks flock conflict with bridge
#   - UFW reset is optional (--no-ufw-reset flag)
#   - Added trap for cleanup on install failure
#   - shellcheck-friendly patterns
set -euo pipefail

# ====== Config (override via env) ======
SUPPORT_USER="${SUPPORT_USER:-support}"
ALLOW_SSH_PORT="${ALLOW_SSH_PORT:-22}"
TAILSCALE_ONLY="${TAILSCALE_ONLY:-0}"

# Multi-port settings
PORT_BASE="${PORT_BASE:-2001}"                  # first local port
CONSOLE_BAUD_DEFAULT="${CONSOLE_BAUD_DEFAULT:-9600}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-900}"
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS:-3600}"
LOGFILE="${LOGFILE:-/var/log/console-gateway-install.log}"

# Optional: custom mapping file (you can edit after install)
MAP_DIR="/etc/console-gateway"
MAP_FILE="${MAP_DIR}/map.tsv"   # columns: dev<TAB>port<TAB>baud<TAB>alias(optional)
MAP_LOCK="/run/console-gateway-map.lock"

# CLI flags
UFW_RESET=1
for arg in "$@"; do
  case "$arg" in
    --no-ufw-reset) UFW_RESET=0 ;;
    --help|-h)
      echo "Usage: sudo $0 [--no-ufw-reset]"
      echo "  --no-ufw-reset   Skip 'ufw --force reset' to preserve existing rules"
      exit 0
      ;;
  esac
done
# =======================================

# ====== Cleanup trap for partial installs ======
INSTALL_STAGE=""
cleanup_on_failure() {
  local rc=$?
  if [[ $rc -ne 0 && -n "$INSTALL_STAGE" ]]; then
    log_error "Installation failed during: ${INSTALL_STAGE}"
    log_error "Review log: ${LOGFILE}"
    log_error "You may need to manually clean up partial changes."
  fi
  exit "$rc"
}
trap cleanup_on_failure EXIT INT TERM

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 600 "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

log()      { echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*\n"; }
log_warn() { echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*\n"; }
log_error(){ echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*\n" >&2; }

require_root(){ [[ "${EUID}" -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }; }

# ====== Validation helpers ======
validate_dev_name() {
  local dev="$1"
  [[ "$dev" =~ ^tty(USB|ACM)[0-9]+$ ]] || return 1
}

validate_port_number() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [[ "$port" -ge 1024 && "$port" -le 65535 ]] || return 1
}

validate_baud_rate() {
  local baud="$1"
  [[ "$baud" =~ ^[0-9]+$ ]] || return 1
  local valid_bauds=(300 1200 2400 4800 9600 19200 38400 57600 115200)
  local b
  for b in "${valid_bauds[@]}"; do
    [[ "$baud" == "$b" ]] && return 0
  done
  return 1
}

validate_alias() {
  local alias_name="$1"
  # Allow empty, or alphanumeric + hyphens + underscores (no shell metacharacters)
  [[ -z "$alias_name" ]] && return 0
  [[ "$alias_name" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || return 1
}

# Read map.tsv with validation, skipping bad lines
# Usage: read_map_validated callback_function
# callback receives: dev port baud alias
read_map_validated() {
  local callback="$1"
  local line_num=0
  [[ -f "$MAP_FILE" ]] || return 0

  while IFS=$'\t' read -r dev port baud alias || [[ -n "$dev" ]]; do
    line_num=$((line_num + 1))
    # Skip empty lines and comments
    [[ -z "$dev" || "$dev" =~ ^# ]] && continue
    # Validate fields
    if ! validate_dev_name "$dev"; then
      log_warn "map.tsv line ${line_num}: invalid device name '${dev}', skipping"
      continue
    fi
    if ! validate_port_number "$port"; then
      log_warn "map.tsv line ${line_num}: invalid port '${port}', skipping"
      continue
    fi
    if [[ -z "$baud" ]] || ! validate_baud_rate "$baud"; then
      log_warn "map.tsv line ${line_num}: invalid baud '${baud}', defaulting to ${CONSOLE_BAUD_DEFAULT}"
      baud="${CONSOLE_BAUD_DEFAULT}"
    fi
    if ! validate_alias "${alias:-}"; then
      log_warn "map.tsv line ${line_num}: invalid alias '${alias}', clearing"
      alias=""
    fi
    "$callback" "$dev" "$port" "$baud" "${alias:-}"
  done < "$MAP_FILE"
}

# Locked write helper for map.tsv
map_locked_write() {
  local tmp_file="$1"
  (
    flock -w 5 200 || { log_error "Cannot acquire map lock"; return 1; }
    cp "$tmp_file" "$MAP_FILE"
  ) 200>"$MAP_LOCK"
}

map_locked_append() {
  local line="$1"
  (
    flock -w 5 200 || { log_error "Cannot acquire map lock"; return 1; }
    printf '%s\n' "$line" >> "$MAP_FILE"
  ) 200>"$MAP_LOCK"
}

validate_basic() {
  INSTALL_STAGE="validate_basic"
  log "Validating..."
  [[ "$PORT_BASE" -ge 1024 && "$PORT_BASE" -le 65500 ]] || { log_error "PORT_BASE invalid: $PORT_BASE"; exit 1; }
  [[ "$ALLOW_SSH_PORT" -ge 1 && "$ALLOW_SSH_PORT" -le 65535 ]] || { log_error "ALLOW_SSH_PORT invalid"; exit 1; }
  [[ "$IDLE_TIMEOUT_SECONDS" -ge 30 && "$IDLE_TIMEOUT_SECONDS" -le 86400 ]] || { log_error "IDLE_TIMEOUT_SECONDS invalid"; exit 1; }
  [[ "$MAX_SESSION_SECONDS" -ge 60 && "$MAX_SESSION_SECONDS" -le 604800 ]] || { log_error "MAX_SESSION_SECONDS invalid"; exit 1; }
  [[ "$SUPPORT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { log_error "SUPPORT_USER invalid"; exit 1; }
  if ! command -v apt-get &>/dev/null; then
    log_error "This script requires a Debian/Ubuntu system with apt-get."
    exit 1
  fi
  log "✓ OK"
}

ensure_packages() {
  INSTALL_STAGE="ensure_packages"
  log "Installing packages..."
  apt-get update -y
  apt-get install -y \
    curl ca-certificates gnupg lsb-release \
    ufw openssh-server \
    socat screen jq net-tools util-linux iproute2 procps unattended-upgrades
  log "✓ Packages installed"
}

setup_unattended_upgrades() {
  INSTALL_STAGE="setup_unattended_upgrades"
  log "Enabling unattended-upgrades..."
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  systemctl enable --now unattended-upgrades 2>/dev/null || true
}

setup_user() {
  INSTALL_STAGE="setup_user"
  log "Setting up user: ${SUPPORT_USER}"
  if ! id -u "${SUPPORT_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${SUPPORT_USER}"
  fi
  usermod -aG dialout "${SUPPORT_USER}"

  local ssh_dir="/home/${SUPPORT_USER}/.ssh"
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  touch "${ssh_dir}/authorized_keys"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown -R "${SUPPORT_USER}:${SUPPORT_USER}" "${ssh_dir}"
  log_warn "IMPORTANT: add SSH key to ${ssh_dir}/authorized_keys"
}

harden_ssh() {
  INSTALL_STAGE="harden_ssh"
  log "Hardening SSH (drop-in)..."
  local d="/etc/ssh/sshd_config.d"
  local f="${d}/90-console-gateway.conf"
  mkdir -p "$d"
  [[ -f "$f" ]] && cp -a "$f" "$f.bak.$(date +%s)"

  cat > "$f" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
UsePAM yes
AllowUsers ${SUPPORT_USER}
MaxAuthTries 3
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  sshd -t
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
  log "✓ SSH hardened"
}

setup_ufw() {
  INSTALL_STAGE="setup_ufw"
  log "Configuring UFW..."

  if [[ "${UFW_RESET}" == "1" ]]; then
    log_warn "Resetting all UFW rules. Use --no-ufw-reset to preserve existing rules."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
  else
    log "Keeping existing UFW rules, adding console-gateway rules only."
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
  fi

  if [[ "${TAILSCALE_ONLY}" == "1" ]]; then
    log_warn "TAILSCALE_ONLY=1: SSH will be restricted to tailscale0 after 'tailscale up'."
    ufw allow "${ALLOW_SSH_PORT}/tcp" comment "SSH (TEMP - restrict to tailscale0 later)"
  else
    ufw allow "${ALLOW_SSH_PORT}/tcp" comment "SSH"
  fi

  ufw allow 41641/udp comment "Tailscale"
  ufw --force enable
  ufw status verbose
}

install_tailscale() {
  INSTALL_STAGE="install_tailscale"
  log "Installing Tailscale..."
  if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled || true
  log_warn "NEXT: run 'sudo tailscale up' to authenticate."
}

install_helpers() {
  INSTALL_STAGE="install_helpers"
  log "Installing helper scripts..."
  cat > /usr/local/bin/console-detect <<'HELPEREOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Serial devices:"
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [[ -e "$dev" ]] && ls -l "$dev"
done
echo
echo "USB serial adapters:"
lsusb | grep -iE "serial|ftdi|prolific|ch340|cp210|silicon" || echo "(none detected)"
HELPEREOF
  chmod +x /usr/local/bin/console-detect

  # console helper: checks for bridge conflict
  cat > /usr/local/bin/console <<'HELPEREOF'
#!/usr/bin/env bash
set -euo pipefail
DEV="${1:-/dev/ttyUSB0}"
BAUD="${2:-9600}"
[[ -e "$DEV" ]] || { echo "No device: $DEV"; exit 1; }

BASE="${DEV##*/}"
LOCK="/run/console-gateway.${BASE}.lock"

# Warn if bridge is holding the device
if [[ -f "$LOCK" ]] && flock -n "$LOCK" true 2>/dev/null; then
  : # lock is free, safe to use
else
  echo "WARNING: console-lock-bridge is active on ${BASE}."
  echo "Using screen directly may conflict with the bridge service."
  echo "Use 'consolectl connect ${BASE}' instead, or 'sudo consolectl kick ${BASE}' first."
  read -rp "Continue anyway? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
fi

exec screen "$DEV" "$BAUD"
HELPEREOF
  chmod +x /usr/local/bin/console
}

write_session_handler() {
  INSTALL_STAGE="write_session_handler"
  log "Installing session handler script..."

  # This is the script socat calls per-connection. Extracted from the old
  # inline SYSTEM:'...' to eliminate nested-quote fragility.
  cat > /usr/local/bin/console-session-handler <<'HANDLEREOF'
#!/usr/bin/env bash
# Called by socat for each incoming connection.
# Required env: CONSOLE_DEV, CONSOLE_BAUD, MAX_SESSION_SECONDS
# Provided by socat: SOCAT_PEERADDR
set -euo pipefail

DEV="${CONSOLE_DEV:?missing CONSOLE_DEV}"
BAUD="${CONSOLE_BAUD:?missing CONSOLE_BAUD}"
MAXS="${MAX_SESSION_SECONDS:-3600}"
BASE="${DEV##*/}"

LOCK="/run/console-gateway.${BASE}.lock"
OWNER="/run/console-gateway.${BASE}.owner"
SESSLOG="/var/log/console-gateway-sessions.log"

TS="$(date +%F_%T)"
PEER="${SOCAT_PEERADDR:-unknown}"

# Acquire exclusive lock (non-blocking)
exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "[busy] Console is in use for ${BASE}. Try later."
  exit 1
fi

# Record session
echo "${TS} dev=${BASE} peer=${PEER} pid=$$" | tee "${OWNER}" >> "${SESSLOG}"
echo "[ok] Locked ${BASE} by ${PEER} (pid=$$) at ${TS}"

# Connect to serial device with max session timeout
exec timeout "${MAXS}" socat - "FILE:${DEV},raw,echo=0,b${BAUD}"
HANDLEREOF
  chmod +x /usr/local/bin/console-session-handler
}

write_bridge_launcher() {
  INSTALL_STAGE="write_bridge_launcher"
  log "Installing bridge launcher..."

  cat > /usr/local/bin/console-lock-bridge <<'BRIDGEEOF'
#!/usr/bin/env bash
set -euo pipefail
DEV="${CONSOLE_DEV:?missing CONSOLE_DEV}"
BAUD="${CONSOLE_BAUD:?missing CONSOLE_BAUD}"
PORT="${LOCAL_CONSOLE_PORT:?missing LOCAL_CONSOLE_PORT}"
# socat -T = inactivity/transfer timeout (not -t which is total shutdown timeout)
IDLE="${IDLE_TIMEOUT_SECONDS:-900}"

echo "[bridge] ${DEV} @ ${BAUD} -> 127.0.0.1:${PORT} idle=${IDLE}s"

# Export env so the session handler inherits them
export CONSOLE_DEV CONSOLE_BAUD MAX_SESSION_SECONDS

exec socat -T"${IDLE}" -d -d \
  "TCP-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork" \
  "EXEC:/usr/local/bin/console-session-handler,pty,raw,echo=0"
BRIDGEEOF
  chmod +x /usr/local/bin/console-lock-bridge
}

install_systemd_template() {
  INSTALL_STAGE="install_systemd_template"
  log "Installing systemd template service..."
  cat > /etc/systemd/system/console-lock-bridge@.service <<EOF
[Unit]
Description=Console Gateway Exclusive Lock Bridge (%i)
After=network.target

[Service]
Type=simple
# These will be overridden by drop-in env files per instance
Environment=CONSOLE_DEV=/dev/%i
Environment=CONSOLE_BAUD=${CONSOLE_BAUD_DEFAULT}
Environment=LOCAL_CONSOLE_PORT=${PORT_BASE}
Environment=IDLE_TIMEOUT_SECONDS=${IDLE_TIMEOUT_SECONDS}
Environment=MAX_SESSION_SECONDS=${MAX_SESSION_SECONDS}
ExecStart=/usr/local/bin/console-lock-bridge
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

generate_mapping() {
  INSTALL_STAGE="generate_mapping"
  log "Generating device->port mapping..."
  mkdir -p "$MAP_DIR"

  # If map exists, keep it (user may have customized)
  if [[ -f "$MAP_FILE" ]]; then
    log_warn "Existing map file found: ${MAP_FILE} (will keep)."
    return 0
  fi

  local i=0
  : > "$MAP_FILE"
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$dev" ]] || continue
    local base="${dev##*/}"
    if ! validate_dev_name "$base"; then
      log_warn "Skipping unexpected device: $dev"
      continue
    fi
    local port=$((PORT_BASE + i))
    printf "%s\t%s\t%s\t%s\n" "$base" "$port" "${CONSOLE_BAUD_DEFAULT}" "" >> "$MAP_FILE"
    i=$((i+1))
  done

  if [[ ! -s "$MAP_FILE" ]]; then
    log_warn "No serial devices detected now. Created empty map: ${MAP_FILE}"
    log_warn "Plug adapters then run: sudo consolectl rescan"
  else
    log "✓ Map created: ${MAP_FILE}"
  fi
}

# Create systemd drop-in for a single device instance
create_instance_dropin() {
  local dev="$1" port="$2" baud="$3"
  local dropdir="/etc/systemd/system/console-lock-bridge@${dev}.service.d"
  mkdir -p "$dropdir"
  cat > "${dropdir}/10-env.conf" <<EOF
[Service]
Environment=CONSOLE_DEV=/dev/${dev}
Environment=CONSOLE_BAUD=${baud}
Environment=LOCAL_CONSOLE_PORT=${port}
Environment=IDLE_TIMEOUT_SECONDS=${IDLE_TIMEOUT_SECONDS}
Environment=MAX_SESSION_SECONDS=${MAX_SESSION_SECONDS}
EOF
}

# Callback for read_map_validated during install
_apply_instance_cb() {
  local dev="$1" port="$2" baud="$3" alias="$4"
  create_instance_dropin "$dev" "$port" "$baud"
  systemctl enable --now "console-lock-bridge@${dev}.service" 2>/dev/null || true
}

apply_instances_from_map() {
  INSTALL_STAGE="apply_instances_from_map"
  log "Enabling bridge instances from map..."
  read_map_validated _apply_instance_cb
  systemctl daemon-reload
  # Restart each known unit explicitly (no glob)
  restart_all_bridge_units
}

# Restart all active bridge units by iterating, not globbing
restart_all_bridge_units() {
  local units
  units=$(systemctl list-units --plain --no-legend 'console-lock-bridge@*' | awk '{print $1}')
  if [[ -n "$units" ]]; then
    local u
    for u in $units; do
      systemctl restart "$u" 2>/dev/null || true
    done
  fi
}

install_logrotate() {
  INSTALL_STAGE="install_logrotate"
  log "Installing logrotate config..."
  cat > /etc/logrotate.d/console-gateway <<'EOF'
/var/log/console-gateway-sessions.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}

/var/log/console-gateway-install.log {
    monthly
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
EOF
  log "✓ Logrotate configured"
}

install_consolectl() {
  INSTALL_STAGE="install_consolectl"
  log "Installing consolectl..."
  cat > /usr/local/bin/consolectl <<CTLEOF
#!/usr/bin/env bash
set -euo pipefail

MAP_FILE="${MAP_FILE}"
MAP_LOCK="${MAP_LOCK}"
PORT_BASE="${PORT_BASE}"
CONSOLE_BAUD_DEFAULT="${CONSOLE_BAUD_DEFAULT}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS}"
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS}"

# ---- Validation helpers (mirrored from installer) ----
validate_dev_name() {
  [[ "\$1" =~ ^tty(USB|ACM)[0-9]+\$ ]]
}
validate_port_number() {
  [[ "\$1" =~ ^[0-9]+\$ ]] && [[ "\$1" -ge 1024 && "\$1" -le 65535 ]]
}
validate_baud_rate() {
  [[ "\$1" =~ ^[0-9]+\$ ]] || return 1
  local valid_bauds=(300 1200 2400 4800 9600 19200 38400 57600 115200)
  local b; for b in "\${valid_bauds[@]}"; do [[ "\$1" == "\$b" ]] && return 0; done
  return 1
}
validate_alias() {
  [[ -z "\$1" ]] && return 0
  [[ "\$1" =~ ^[a-zA-Z0-9_-]{1,64}\$ ]]
}

usage() {
  echo "Usage:"
  echo "  consolectl list                       Show device map"
  echo "  consolectl connect <alias|dev|port>   Connect to console"
  echo "  consolectl owner <dev>                Show current lock owner"
  echo "  consolectl tail [N]                   Show recent session log"
  echo "  sudo consolectl kick <dev>            Force-disconnect user"
  echo "  sudo consolectl rescan                Detect new devices & start bridges"
  echo "  consolectl status                     Quick health check"
}

list_map() {
  if [[ ! -f "\$MAP_FILE" ]]; then
    echo "No map: \$MAP_FILE"
    exit 1
  fi
  printf "%-12s %-6s %-8s %-20s %s\n" "DEV" "PORT" "BAUD" "ALIAS" "STATUS"
  printf '%0.s-' {1..60}; echo
  while IFS=\$'\t' read -r dev port baud alias; do
    [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
    validate_dev_name "\$dev" || continue
    validate_port_number "\$port" || continue
    # Check if service is active
    local status="stopped"
    if systemctl is-active --quiet "console-lock-bridge@\${dev}.service" 2>/dev/null; then
      status="running"
    fi
    printf "%-12s %-6s %-8s %-20s %s\n" "\$dev" "\$port" "\$baud" "\${alias:-}" "\$status"
  done < "\$MAP_FILE"
}

resolve_target() {
  local t="\$1"
  # If it's a port number
  if [[ "\$t" =~ ^[0-9]+\$ ]]; then
    echo "\$t"
    return 0
  fi
  # If it's a dev name
  if validate_dev_name "\$t"; then
    awk -F'\t' -v d="\$t" '\$1==d{print \$2; exit}' "\$MAP_FILE"
    return 0
  fi
  # Else treat as alias (validate first)
  if validate_alias "\$t"; then
    awk -F'\t' -v a="\$t" '\$4==a{print \$2; exit}' "\$MAP_FILE"
    return 0
  fi
  return 1
}

do_rescan() {
  [[ "\${EUID}" -eq 0 ]] || { echo "rescan needs sudo"; exit 1; }

  # Build set of existing devs
  declare -A seen
  local maxp=\$PORT_BASE
  if [[ -f "\$MAP_FILE" ]]; then
    while IFS=\$'\t' read -r dev port baud alias; do
      [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
      validate_dev_name "\$dev" || continue
      seen["\$dev"]=1
      if validate_port_number "\$port" && (( port > maxp )); then
        maxp=\$port
      fi
    done < "\$MAP_FILE"
  fi
  local nextp=\$((maxp + 1))
  local new_count=0

  for d in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "\$d" ]] || continue
    local base="\${d##*/}"
    validate_dev_name "\$base" || continue
    if [[ -z "\${seen[\$base]:-}" ]]; then
      # Append to map (locked)
      (
        flock -w 5 200 || { echo "Cannot acquire map lock"; exit 1; }
        printf "%s\t%s\t%s\t%s\n" "\$base" "\$nextp" "\$CONSOLE_BAUD_DEFAULT" "" >> "\$MAP_FILE"
      ) 200>"\$MAP_LOCK"

      # Create systemd drop-in
      local dropdir="/etc/systemd/system/console-lock-bridge@\${base}.service.d"
      mkdir -p "\$dropdir"
      cat > "\${dropdir}/10-env.conf" <<DROPEOF
[Service]
Environment=CONSOLE_DEV=/dev/\${base}
Environment=CONSOLE_BAUD=\${CONSOLE_BAUD_DEFAULT}
Environment=LOCAL_CONSOLE_PORT=\${nextp}
Environment=IDLE_TIMEOUT_SECONDS=\${IDLE_TIMEOUT_SECONDS}
Environment=MAX_SESSION_SECONDS=\${MAX_SESSION_SECONDS}
DROPEOF

      systemctl daemon-reload
      systemctl enable --now "console-lock-bridge@\${base}.service" 2>/dev/null || true
      echo "[new] \${base} -> port \${nextp}"
      nextp=\$((nextp + 1))
      new_count=\$((new_count + 1))
    fi
  done

  if [[ \$new_count -eq 0 ]]; then
    echo "No new devices found."
  else
    echo "Added \${new_count} new device(s). Map: \$MAP_FILE"
  fi
}

case "\${1:-}" in
  list)
    list_map
    ;;
  connect)
    [[ -n "\${2:-}" ]] || { usage; exit 1; }
    port=\$(resolve_target "\$2" || true)
    [[ -n "\$port" ]] || { echo "Cannot resolve: \$2"; exit 1; }
    echo "[connect] localhost:\$port"
    exec socat - "TCP:127.0.0.1:\$port"
    ;;
  owner)
    [[ -n "\${2:-}" ]] || { usage; exit 1; }
    dev="\$2"
    validate_dev_name "\$dev" || { echo "Use dev like ttyUSB0"; exit 1; }
    f="/run/console-gateway.\${dev}.owner"
    [[ -f "\$f" ]] && cat "\$f" || echo "none"
    ;;
  tail)
    n="\${2:-50}"
    tail -n "\$n" /var/log/console-gateway-sessions.log 2>/dev/null || echo "(no log yet)"
    ;;
  kick)
    [[ "\${EUID}" -eq 0 ]] || { echo "kick needs sudo"; exit 1; }
    [[ -n "\${2:-}" ]] || { usage; exit 1; }
    dev="\$2"
    validate_dev_name "\$dev" || { echo "Invalid device: \$dev"; exit 1; }
    systemctl restart "console-lock-bridge@\${dev}.service"
    echo "Kicked sessions on \${dev}"
    ;;
  rescan)
    do_rescan
    ;;
  status)
    echo "=== Console Gateway Status ==="
    date
    echo
    (systemctl is-active --quiet sshd || systemctl is-active --quiet ssh) && echo "SSH: OK" || echo "SSH: DOWN"
    command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && echo "Tailscale: OK" || echo "Tailscale: NOT CONNECTED"
    echo
    echo "Bridge instances:"
    systemctl list-units --type=service "console-lock-bridge@*" --no-pager 2>/dev/null || echo "(none)"
    echo
    list_map 2>/dev/null || echo "(no map)"
    ;;
  *)
    usage
    exit 1
    ;;
esac
CTLEOF
  chmod +x /usr/local/bin/consolectl
}

install_healthcheck() {
  INSTALL_STAGE="install_healthcheck"
  log "Installing healthcheck..."
  cat > /usr/local/bin/console-healthcheck <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "=== Console Gateway Health ==="
date
echo
(systemctl is-active --quiet sshd || systemctl is-active --quiet ssh) && echo "SSH: OK" || echo "SSH: DOWN"
command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && echo "Tailscale: OK" || echo "Tailscale: NOT CONNECTED"
echo
echo "Instances:"
systemctl list-units --type=service "console-lock-bridge@*" --no-pager 2>/dev/null || true
echo
echo "Map:"
consolectl list 2>/dev/null || echo "(no map)"
EOF
  chmod +x /usr/local/bin/console-healthcheck
}

create_uninstall() {
  INSTALL_STAGE="create_uninstall"
  log "Creating uninstall script..."
  cat > /usr/local/bin/console-gateway-uninstall <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "sudo required"; exit 1; }
read -rp "Type 'yes' to uninstall Console Gateway: " a
[[ "$a" == "yes" ]] || exit 0

echo "Stopping bridge services..."
units=$(systemctl list-units --plain --no-legend 'console-lock-bridge@*' | awk '{print $1}')
for u in $units; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
done

rm -f /etc/systemd/system/console-lock-bridge@.service
rm -rf /etc/systemd/system/console-lock-bridge@*.service.d
systemctl daemon-reload

rm -f /etc/ssh/sshd_config.d/90-console-gateway.conf
rm -rf /etc/console-gateway
rm -f /etc/logrotate.d/console-gateway
rm -f /usr/local/bin/console-lock-bridge
rm -f /usr/local/bin/console-session-handler
rm -f /usr/local/bin/consolectl
rm -f /usr/local/bin/console-healthcheck
rm -f /usr/local/bin/console
rm -f /usr/local/bin/console-detect
rm -f /usr/local/bin/console-port
rm -f /run/console-gateway.*.lock /run/console-gateway.*.owner

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
echo "Done. Check UFW: ufw status verbose"
echo "Note: Tailscale and UFW rules were not removed."
EOF
  chmod +x /usr/local/bin/console-gateway-uninstall
}

post_notes() {
  # Clear install stage on success
  INSTALL_STAGE=""

  cat <<EOF

✅ Console Gateway v2.4 installed (multi-port, exclusive per port)

1) Plug USB-serial adapters, then:
   console-detect
   consolectl list

2) Start Tailscale:
   sudo tailscale up
   tailscale ip -4

3) Supporter (choose target port):
   ssh -L <PORT>:localhost:<PORT> ${SUPPORT_USER}@<PI_TAILSCALE_IP>
   consolectl connect <alias|dev|port>
   # If busy: second user gets [busy] (exclusive lock)

4) Optional: set friendly alias names
   sudo nano ${MAP_FILE}
   # Add alias in 4th column, e.g.
   # ttyUSB0    2001    9600    SW-TPERP-NWCS01
   # Allowed: alphanumeric, hyphens, underscores (max 64 chars)

5) Apply changes after editing map:
   sudo consolectl rescan        # detects new devices + starts bridges
   sudo systemctl daemon-reload  # if you edited existing entries

6) Operations:
   consolectl list               # show all ports + status
   consolectl owner ttyUSB0      # who holds the lock
   consolectl tail               # recent session log
   sudo consolectl kick ttyUSB0  # force-disconnect
   consolectl status             # quick health check

TAILSCALE_ONLY=${TAILSCALE_ONLY}
EOF

  if [[ "${TAILSCALE_ONLY}" == "1" ]]; then
    cat <<EOF
After tailscale up, lock SSH to tailscale0:
  sudo ufw delete allow ${ALLOW_SSH_PORT}/tcp
  sudo ufw allow in on tailscale0 to any port ${ALLOW_SSH_PORT} proto tcp
  sudo ufw status verbose
EOF
  fi
}

main() {
  require_root
  validate_basic
  ensure_packages
  setup_unattended_upgrades
  setup_user
  harden_ssh
  setup_ufw
  install_tailscale
  install_helpers
  write_session_handler
  write_bridge_launcher
  install_systemd_template
  generate_mapping
  apply_instances_from_map
  install_logrotate
  install_consolectl
  install_healthcheck
  create_uninstall
  post_notes
}

main "$@"
