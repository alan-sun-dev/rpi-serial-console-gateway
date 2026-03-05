#!/usr/bin/env bash
# Console Gateway v2.9 - Multi-port Exclusive Console Server (Tailscale + SSH + socat+flock)
# Fixes over v2.8 (delta review findings):
#   - Fix: session handler removed redundant manual cleanup() call; trap EXIT handles it
#   - Fix: generate_mapping() uses independent device_count + next_port counters to
#     avoid miscounting when ports are skipped due to conflicts
set -euo pipefail

# ====== Config (override via env) ======
SUPPORT_USER="${SUPPORT_USER:-support}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
ALLOW_SSH_PORT="${ALLOW_SSH_PORT:-22}"
TAILSCALE_ONLY="${TAILSCALE_ONLY:-0}"

# Multi-port settings
PORT_BASE="${PORT_BASE:-2001}"                  # first local port
CONSOLE_BAUD_DEFAULT="${CONSOLE_BAUD_DEFAULT:-9600}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-900}"
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS:-3600}"
LOGFILE="${LOGFILE:-/var/log/console-gateway-install.log}"

# Paths
MAP_DIR="/etc/console-gateway"
MAP_FILE="${MAP_DIR}/map.tsv"   # columns: symlink<TAB>port<TAB>baud<TAB>alias
MAP_LOCK="/run/console-gateway-map.lock"
UDEV_RULES_FILE="/etc/udev/rules.d/90-console-gateway.rules"

# CLI flags
UFW_RESET=0
for arg in "$@"; do
  case "$arg" in
    --ufw-reset) UFW_RESET=1 ;;
    --help|-h)
      echo "Usage: sudo $0 [--ufw-reset]"
      echo "  --ufw-reset   Reset all UFW rules before configuring (destructive)"
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
# Device names: ttyUSB0, ttyACM0 (raw kernel names)
validate_dev_name() {
  [[ "$1" =~ ^tty(USB|ACM)[0-9]+$ ]]
}

# Symlink names: cgw-<alias> (our managed symlinks)
validate_symlink_name() {
  [[ "$1" =~ ^cgw-[a-zA-Z0-9_-]{1,60}$ ]]
}

# Map device field: either a kernel name or our symlink
validate_map_dev() {
  validate_dev_name "$1" || validate_symlink_name "$1"
}

validate_port_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1024 && "$1" -le 65535 ]]
}

validate_baud_rate() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  local valid_bauds=(300 1200 2400 4800 9600 19200 38400 57600 115200)
  local b
  for b in "${valid_bauds[@]}"; do
    [[ "$1" == "$b" ]] && return 0
  done
  return 1
}

validate_alias() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}$ ]]
}

# Read map.tsv with validation, calling callback for each valid line
read_map_validated() {
  local callback="$1"
  local line_num=0
  [[ -f "$MAP_FILE" ]] || return 0

  while IFS=$'\t' read -r dev port baud alias || [[ -n "$dev" ]]; do
    line_num=$((line_num + 1))
    [[ -z "$dev" || "$dev" =~ ^# ]] && continue
    if ! validate_map_dev "$dev"; then
      log_warn "map.tsv line ${line_num}: invalid device '${dev}', skipping"
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

validate_basic() {
  INSTALL_STAGE="validate_basic"
  log "Validating..."
  [[ "$PORT_BASE" -ge 1024 && "$PORT_BASE" -le 65500 ]] || { log_error "PORT_BASE invalid: $PORT_BASE"; exit 1; }
  [[ "$ALLOW_SSH_PORT" -ge 1 && "$ALLOW_SSH_PORT" -le 65535 ]] || { log_error "ALLOW_SSH_PORT invalid"; exit 1; }
  [[ "$IDLE_TIMEOUT_SECONDS" -ge 30 && "$IDLE_TIMEOUT_SECONDS" -le 86400 ]] || { log_error "IDLE_TIMEOUT_SECONDS invalid"; exit 1; }
  [[ "$MAX_SESSION_SECONDS" -ge 60 && "$MAX_SESSION_SECONDS" -le 604800 ]] || { log_error "MAX_SESSION_SECONDS invalid"; exit 1; }
  [[ "$SUPPORT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { log_error "SUPPORT_USER invalid"; exit 1; }
  validate_baud_rate "$CONSOLE_BAUD_DEFAULT" || { log_error "CONSOLE_BAUD_DEFAULT invalid: $CONSOLE_BAUD_DEFAULT"; exit 1; }
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
    socat screen util-linux iproute2 procps unattended-upgrades
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
AllowUsers ${SUPPORT_USER}${ADMIN_USER:+ ${ADMIN_USER}}
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
    log_warn "Resetting all UFW rules (--ufw-reset was specified)."
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
    # Use official apt repo instead of curl|sh to avoid supply-chain risk
    local distro ts_family
    distro=$(lsb_release -cs 2>/dev/null || echo "bookworm")
    if grep -qi ubuntu /etc/os-release 2>/dev/null; then
      ts_family="ubuntu"
    else
      ts_family="debian"
    fi
    curl -fsSL "https://pkgs.tailscale.com/stable/${ts_family}/${distro}.noarmor.gpg" \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/${ts_family}/${distro}.tailscale-keyring.list" \
      | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update -y
    apt-get install -y tailscale
  fi
  systemctl enable --now tailscaled || true
  log_warn "NEXT: run 'sudo tailscale up' to authenticate."
}

install_helpers() {
  INSTALL_STAGE="install_helpers"
  log "Installing helper scripts..."

  # console-detect: shows serial devices WITH USB attributes for udev rule creation
  cat > /usr/local/bin/console-detect <<'HELPEREOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== Serial Devices ==="
echo
found=0
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [[ -e "$dev" ]] || continue
  found=1
  base="${dev##*/}"

  # Get USB attributes via udevadm properties (ENV) — works across parent levels
  props=$(udevadm info -q property -n "$dev" 2>/dev/null)
  vendor=$(echo "$props" | grep '^ID_USB_VENDOR_ID=' | cut -d= -f2)
  product=$(echo "$props" | grep '^ID_USB_MODEL_ID=' | cut -d= -f2)
  serial=$(echo "$props" | grep '^ID_USB_SERIAL_SHORT=' | cut -d= -f2)
  manufacturer=$(echo "$props" | grep '^ID_USB_VENDOR=' | cut -d= -f2)
  product_name=$(echo "$props" | grep '^ID_MODEL_FROM_DATABASE=' | cut -d= -f2-)
  iface_num=$(echo "$props" | grep '^ID_USB_INTERFACE_NUM=' | cut -d= -f2)

  # Check for existing symlinks managed by us
  symlink=""
  for s in /dev/cgw-*; do
    [[ -e "$s" ]] || continue
    if [[ "$(readlink -f "$s")" == "$(readlink -f "$dev")" ]]; then
      symlink="${s##*/}"
      break
    fi
  done

  printf "  %-12s" "$base"
  [[ -n "$symlink" ]] && printf " -> %-24s" "$symlink" || printf "    %-24s" "(no alias)"
  echo
  printf "    %-14s %s\n" "Manufacturer:" "${manufacturer:-unknown}"
  printf "    %-14s %s\n" "Product:" "${product_name:-unknown}"
  printf "    %-14s %s\n" "Vendor ID:" "${vendor:-unknown}"
  printf "    %-14s %s\n" "Product ID:" "${product:-unknown}"
  printf "    %-14s %s\n" "Serial:" "${serial:-none}"
  [[ -n "$iface_num" ]] && printf "    %-14s %s\n" "Interface:" "$iface_num"

  # Uniqueness assessment
  if [[ -n "$serial" && "$serial" != "none" ]]; then
    echo "    Uniqueness:    ✓ Has serial number (ideal for udev rule)"
  elif [[ -n "$vendor" && -n "$product" ]]; then
    echo "    Uniqueness:    ⚠ No serial; rule will match ALL adapters of this model"
  else
    echo "    Uniqueness:    ✗ Insufficient attributes for reliable udev rule"
  fi
  echo
done

if [[ $found -eq 0 ]]; then
  echo "  (no serial devices found)"
  echo
fi

echo "=== USB Adapters (lsusb) ==="
lsusb | grep -iE "serial|ftdi|prolific|ch340|cp210|silicon|uart|rs232" || echo "  (none matching known chipsets)"
echo
echo "=== Managed Symlinks ==="
ls -la /dev/cgw-* 2>/dev/null || echo "  (none — run 'sudo consolectl addconsole' to create)"
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

if [[ -f "$LOCK" ]] && ! flock -n "$LOCK" true 2>/dev/null; then
  echo "WARNING: console-lock-bridge is active on ${BASE}."
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

# Validate baud rate to prevent injection via socat address spec
if [[ ! "$BAUD" =~ ^[0-9]+$ ]]; then
  echo "[error] Invalid baud rate: $BAUD" >&2
  exit 1
fi

LOCK="/run/console-gateway.${BASE}.lock"
OWNER="/run/console-gateway.${BASE}.owner"
SESSLOG="/var/log/console-gateway-sessions.log"

TS="$(date +%F_%T)"
PEER="${SOCAT_PEERADDR:-unknown}"

# Clean up owner file on exit
cleanup() { rm -f "${OWNER}" 2>/dev/null; }
trap cleanup EXIT INT TERM

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
timeout "${MAXS}" socat - "FILE:${DEV},raw,echo=0,b${BAUD}" || true
# cleanup is handled by trap EXIT — no manual call needed
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

# Validate baud and port to prevent injection via socat address spec
[[ "$BAUD" =~ ^[0-9]+$ ]] || { echo "[error] Invalid baud: $BAUD" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "[error] Invalid port: $PORT" >&2; exit 1; }

echo "[bridge] ${DEV} @ ${BAUD} -> 127.0.0.1:${PORT} idle=${IDLE}s"

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
BindsTo=dev-%i.device
After=dev-%i.device

[Service]
Type=simple
Environment=CONSOLE_DEV=/dev/%i
Environment=CONSOLE_BAUD=${CONSOLE_BAUD_DEFAULT}
Environment=LOCAL_CONSOLE_PORT=${PORT_BASE}
Environment=IDLE_TIMEOUT_SECONDS=${IDLE_TIMEOUT_SECONDS}
Environment=MAX_SESSION_SECONDS=${MAX_SESSION_SECONDS}
ExecStart=/usr/local/bin/console-lock-bridge
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/run /var/log /dev
RestrictAddressFamilies=AF_INET AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

setup_udev_rules() {
  INSTALL_STAGE="setup_udev_rules"
  log "Setting up udev rules infrastructure..."
  mkdir -p "$MAP_DIR"

  # Create the rules file with header if it doesn't exist
  if [[ ! -f "$UDEV_RULES_FILE" ]]; then
    cat > "$UDEV_RULES_FILE" <<'EOF'
# Console Gateway - Persistent USB-serial adapter naming
# Managed by consolectl addconsole / rmconsole
# Manual edits are supported but use consolectl when possible.
#
# Each rule creates a symlink /dev/cgw-<ALIAS> for a specific adapter.
# Rules match on USB attributes (vendor, product, serial) so the
# symlink persists regardless of which USB port the adapter is in.
EOF
    udevadm control --reload-rules 2>/dev/null || true
    log "✓ Created udev rules file: ${UDEV_RULES_FILE}"
  else
    log "✓ Existing udev rules file preserved: ${UDEV_RULES_FILE}"
  fi
}

generate_mapping() {
  INSTALL_STAGE="generate_mapping"
  log "Generating device->port mapping..."
  mkdir -p "$MAP_DIR"

  if [[ -f "$MAP_FILE" ]]; then
    log_warn "Existing map file found: ${MAP_FILE} (will keep)."
    return 0
  fi

  # Create map with header comment
  cat > "$MAP_FILE" <<'EOF'
# Console Gateway device map
# Format: device<TAB>port<TAB>baud<TAB>alias
# device = kernel name (ttyUSB0) or managed symlink (cgw-SW-CORE-01)
# Use 'sudo consolectl addconsole' to add devices with persistent naming
EOF

  # Auto-detect currently plugged devices (as ttyUSB* for initial bootstrap)
  local device_count=0
  local next_port=$PORT_BASE
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$dev" ]] || continue
    local base="${dev##*/}"
    validate_dev_name "$base" || continue
    # Skip ports already in use by other services
    while ss -tlnp sport = :${next_port} 2>/dev/null | grep -q ":${next_port}\b"; do
      next_port=$((next_port + 1))
    done
    printf "%s\t%s\t%s\t%s\n" "$base" "$next_port" "${CONSOLE_BAUD_DEFAULT}" "" >> "$MAP_FILE"
    next_port=$((next_port + 1))
    device_count=$((device_count + 1))
  done

  if [[ $device_count -eq 0 ]]; then
    log_warn "No serial devices detected. Plug adapters then run: sudo consolectl addconsole"
  else
    log "✓ Map created with ${device_count} device(s): ${MAP_FILE}"
    log_warn "These use kernel names (ttyUSB0) which may drift on reboot."
    log_warn "Run 'sudo consolectl addconsole' to create persistent aliases."
  fi
}

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
  restart_all_bridge_units
}

restart_all_bridge_units() {
  local units
  units=$(systemctl list-units --plain --no-legend 'console-lock-bridge@*' 2>/dev/null | awk '{print $1}')
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
MAP_DIR="${MAP_DIR}"
PORT_BASE="${PORT_BASE}"
CONSOLE_BAUD_DEFAULT="${CONSOLE_BAUD_DEFAULT}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS}"
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS}"
UDEV_RULES_FILE="${UDEV_RULES_FILE}"

# ---- Validation ----
validate_dev_name()     { [[ "\$1" =~ ^tty(USB|ACM)[0-9]+\$ ]]; }
validate_symlink_name() { [[ "\$1" =~ ^cgw-[a-zA-Z0-9_-]{1,60}\$ ]]; }
validate_map_dev()      { validate_dev_name "\$1" || validate_symlink_name "\$1"; }
validate_port_number()  { [[ "\$1" =~ ^[0-9]+\$ ]] && [[ "\$1" -ge 1024 && "\$1" -le 65535 ]]; }
validate_baud_rate() {
  [[ "\$1" =~ ^[0-9]+\$ ]] || return 1
  local valid_bauds=(300 1200 2400 4800 9600 19200 38400 57600 115200)
  local b; for b in "\${valid_bauds[@]}"; do [[ "\$1" == "\$b" ]] && return 0; done
  return 1
}
validate_alias() {
  [[ -z "\$1" ]] && return 0
  [[ "\$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}\$ ]]
}

usage() {
  cat <<USAGE
Console Gateway CLI

Usage:
  consolectl list                       Show device map with status
  consolectl connect <alias|dev|port>   Connect to console
  consolectl owner <dev>                Show current lock owner
  consolectl tail [N]                   Show recent session log
  consolectl status                     Quick health check

  sudo consolectl addconsole            Interactive: add adapter with persistent naming
  sudo consolectl rmconsole <alias>     Remove adapter alias, udev rule, and bridge
  sudo consolectl kick <dev>            Force-disconnect active session
  sudo consolectl rescan                Detect new devices & start bridges
USAGE
}

# ---- Get next available port ----
next_available_port() {
  local maxp=\$PORT_BASE
  if [[ -f "\$MAP_FILE" ]]; then
    while IFS=\$'\t' read -r dev port baud alias; do
      [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
      [[ "\$port" =~ ^[0-9]+\$ ]] || continue
      (( port >= maxp )) && maxp=\$((port + 1))
    done < "\$MAP_FILE"
  fi
  # Return maxp (which is already +1 from highest found, or PORT_BASE if empty)
  local port
  [[ \$maxp -eq \$PORT_BASE ]] && port=\$PORT_BASE || port=\$maxp
  # Skip ports already in use by other services
  while ss -tlnp sport = :\${port} 2>/dev/null | grep -q ":\${port}\b"; do
    port=\$((port + 1))
  done
  echo \$port
}

# ---- Check if alias already exists in map ----
alias_exists_in_map() {
  local check="\$1"
  [[ -f "\$MAP_FILE" ]] || return 1
  while IFS=\$'\t' read -r dev port baud alias; do
    [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
    # Check symlink name
    [[ "\$dev" == "cgw-\${check}" ]] && return 0
    # Check alias column
    [[ "\${alias:-}" == "\$check" ]] && return 0
  done < "\$MAP_FILE"
  return 1
}

# ---- Get USB attributes for a device ----
# Uses ENV{} properties (udevadm info -q property) instead of ATTRS{} (udevadm info -a).
# ATTRS{} can only match attributes from ONE parent device in the sysfs tree.
# Multi-port adapters (e.g. FT4232H) have bInterfaceNumber on the interface-level
# parent and serial on the USB-device-level parent — ATTRS{} cannot cross parents,
# causing rules to silently fail.  ENV{ID_USB_*} properties are flattened by udev
# and can be freely combined in a single rule.
get_usb_attrs() {
  local dev_path="\$1"
  local props
  props=\$(udevadm info -q property -n "\$dev_path" 2>/dev/null)
  UDEV_VENDOR=\$(echo "\$props" | grep '^ID_USB_VENDOR_ID=' | cut -d= -f2)
  UDEV_PRODUCT=\$(echo "\$props" | grep '^ID_USB_MODEL_ID=' | cut -d= -f2)
  UDEV_SERIAL=\$(echo "\$props" | grep '^ID_USB_SERIAL_SHORT=' | cut -d= -f2)
  UDEV_MANUFACTURER=\$(echo "\$props" | grep '^ID_USB_VENDOR=' | cut -d= -f2)
  UDEV_PRODUCT_NAME=\$(echo "\$props" | grep '^ID_MODEL_FROM_DATABASE=' | cut -d= -f2-)
  UDEV_IFACE_NUM=\$(echo "\$props" | grep '^ID_USB_INTERFACE_NUM=' | cut -d= -f2)
}

# ======== ADDCONSOLE ========
do_addconsole() {
  [[ "\${EUID}" -eq 0 ]] || { echo "addconsole needs sudo"; exit 1; }

  echo "=== Console Gateway - Add Console Adapter ==="
  echo
  echo "Scanning for serial devices..."
  echo

  # Find all serial devices
  local devs=()
  for d in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "\$d" ]] && devs+=("\$d")
  done

  if [[ \${#devs[@]} -eq 0 ]]; then
    echo "No serial devices found. Plug in a USB-serial adapter and try again."
    exit 1
  fi

  # Display devices with attributes
  echo "Available devices:"
  echo
  local i=0
  for d in "\${devs[@]}"; do
    base="\${d##*/}"
    get_usb_attrs "\$d"
    i=\$((i + 1))
    printf "  [%d] %-12s  %s %s" "\$i" "\$base" "\${UDEV_MANUFACTURER:-unknown}" "\${UDEV_PRODUCT_NAME:-}"
    if [[ -n "\$UDEV_SERIAL" ]]; then
      printf "  (S/N: %s)" "\$UDEV_SERIAL"
    fi
    if [[ -n "\${UDEV_IFACE_NUM:-}" ]]; then
      printf "  [if:%s]" "\$UDEV_IFACE_NUM"
    fi
    # Show if already has a symlink
    for s in /dev/cgw-*; do
      [[ -e "\$s" ]] || continue
      if [[ "\$(readlink -f "\$s")" == "\$(readlink -f "\$d")" ]]; then
        printf "  [already aliased: %s]" "\${s##*/}"
        break
      fi
    done
    echo
  done
  echo

  # Select device
  local sel
  read -rp "Select device number [1-\${#devs[@]}]: " sel
  if [[ ! "\$sel" =~ ^[0-9]+\$ ]] || [[ "\$sel" -lt 1 || "\$sel" -gt \${#devs[@]} ]]; then
    echo "Invalid selection."; exit 1
  fi
  local selected_dev="\${devs[\$((sel-1))]}"
  local selected_base="\${selected_dev##*/}"
  echo
  echo "Selected: \$selected_dev"

  # Get USB attributes
  get_usb_attrs "\$selected_dev"
  echo
  echo "USB attributes:"
  echo "  Vendor:    \${UDEV_VENDOR:-unknown} (\${UDEV_MANUFACTURER:-})"
  echo "  Product:   \${UDEV_PRODUCT:-unknown} (\${UDEV_PRODUCT_NAME:-})"
  echo "  Serial:    \${UDEV_SERIAL:-none}"
  echo "  Interface: \${UDEV_IFACE_NUM:-N/A}"
  echo

  # Warn if no serial number
  if [[ -z "\$UDEV_SERIAL" || "\$UDEV_SERIAL" == "none" ]]; then
    echo "⚠  WARNING: This adapter has no unique serial number."
    echo "   The udev rule will match ALL adapters with the same vendor/product IDs."
    echo "   If you have multiple identical adapters, consider:"
    echo "   - Using adapters with unique serial numbers (e.g., FTDI)"
    echo "   - Assigning by physical USB port (less flexible)"
    echo
    read -rp "Continue anyway? (y/N): " cont
    [[ "\$cont" =~ ^[Yy]\$ ]] || exit 0
    echo
  fi

  # Warn about multi-port adapters sharing the same serial number
  if [[ -n "\${UDEV_IFACE_NUM:-}" && -n "\$UDEV_SERIAL" && "\$UDEV_SERIAL" != "none" ]]; then
    # Count how many ports share this serial number
    local sibling_count=0
    for sd in /dev/ttyUSB* /dev/ttyACM*; do
      [[ -e "\$sd" ]] || continue
      local sd_serial
      sd_serial=\$(udevadm info -q property -n "\$sd" 2>/dev/null | grep '^ID_USB_SERIAL_SHORT=' | cut -d= -f2)
      [[ "\$sd_serial" == "\$UDEV_SERIAL" ]] && sibling_count=\$((sibling_count + 1))
    done
    if [[ \$sibling_count -gt 1 ]]; then
      echo "ℹ  Multi-port adapter detected (\${sibling_count} ports share S/N: \${UDEV_SERIAL})."
      echo "   Interface number \${UDEV_IFACE_NUM} will be included in the udev rule"
      echo "   to uniquely identify this specific port."
      echo
    fi
  fi

  # Get alias name
  local alias_name
  while true; do
    read -rp "Alias name (e.g. SW-CORE-01, RTR-WAN-01): " alias_name
    if [[ -z "\$alias_name" ]]; then
      echo "Alias cannot be empty."
      continue
    fi
    if ! validate_alias "\$alias_name"; then
      echo "Invalid alias. Use alphanumeric, hyphens, underscores (max 60 chars, start with letter/digit)."
      continue
    fi
    if alias_exists_in_map "\$alias_name"; then
      echo "Alias '\$alias_name' already exists in map. Choose another."
      continue
    fi
    break
  done

  # Get baud rate
  local baud
  read -rp "Baud rate [${CONSOLE_BAUD_DEFAULT}]: " baud
  baud="\${baud:-${CONSOLE_BAUD_DEFAULT}}"
  if ! validate_baud_rate "\$baud"; then
    echo "Invalid baud rate. Using default: ${CONSOLE_BAUD_DEFAULT}"
    baud="${CONSOLE_BAUD_DEFAULT}"
  fi

  # Assign port
  local port
  port=\$(next_available_port)
  echo
  echo "Assigned port: \$port"

  local symlink_name="cgw-\${alias_name}"

  # ---- Summary ----
  echo
  echo "┌─────────────────────────────────────────────┐"
  echo "│  Summary                                    │"
  echo "├─────────────────────────────────────────────┤"
  printf "│  Device:    %.32s│\n" "\$(printf '%-32s' "\$selected_base")"
  printf "│  Alias:     %.32s│\n" "\$(printf '%-32s' "\$alias_name")"
  printf "│  Symlink:   %.32s│\n" "\$(printf '%-32s' "/dev/\$symlink_name")"
  printf "│  Port:      %.32s│\n" "\$(printf '%-32s' "\$port")"
  printf "│  Baud:      %.32s│\n" "\$(printf '%-32s' "\$baud")"
  printf "│  Vendor:    %.32s│\n" "\$(printf '%-32s' "\${UDEV_VENDOR:-?}:\${UDEV_PRODUCT:-?}")"
  printf "│  Serial:    %.32s│\n" "\$(printf '%-32s' "\${UDEV_SERIAL:-none}")"
  printf "│  Interface: %.32s│\n" "\$(printf '%-32s' "\${UDEV_IFACE_NUM:-N/A}")"
  echo "└─────────────────────────────────────────────┘"
  echo
  read -rp "Apply these settings? (Y/n): " confirm
  [[ "\$confirm" =~ ^[Nn]\$ ]] && { echo "Cancelled."; exit 0; }

  # ---- 1. Create udev rule ----
  echo
  echo "[1/5] Creating udev rule..."
  # Use ENV{ID_USB_*} properties instead of ATTRS{} — ENV properties are flattened
  # by udev and can be freely combined, unlike ATTRS{} which is limited to one parent
  local rule='SUBSYSTEM=="tty"'
  rule="\${rule}, ENV{ID_USB_VENDOR_ID}==\"\${UDEV_VENDOR}\""
  rule="\${rule}, ENV{ID_USB_MODEL_ID}==\"\${UDEV_PRODUCT}\""
  if [[ -n "\$UDEV_SERIAL" && "\$UDEV_SERIAL" != "none" ]]; then
    rule="\${rule}, ENV{ID_USB_SERIAL_SHORT}==\"\${UDEV_SERIAL}\""
  fi
  if [[ -n "\${UDEV_IFACE_NUM:-}" ]]; then
    rule="\${rule}, ENV{ID_USB_INTERFACE_NUM}==\"\${UDEV_IFACE_NUM}\""
  fi
  rule="\${rule}, SYMLINK+=\"\${symlink_name}\""
  rule="\${rule}, TAG+=\"console-gateway\""

  # Append to rules file (with comment)
  {
    echo "# \${alias_name} (\${UDEV_MANUFACTURER:-} \${UDEV_PRODUCT_NAME:-}) added \$(date +%F)"
    echo "\$rule"
  } >> "\$UDEV_RULES_FILE"

  udevadm control --reload-rules
  udevadm trigger --subsystem-match=tty
  # Brief wait for symlink to appear
  sleep 1

  if [[ -e "/dev/\${symlink_name}" ]]; then
    echo "  ✓ Symlink /dev/\${symlink_name} -> \$(readlink -f "/dev/\${symlink_name}")"
  else
    echo "  ⚠ Symlink not yet active (will appear on next plug/reboot)"
  fi

  # ---- 2. Add to map.tsv ----
  echo "[2/5] Updating map..."
  (
    flock -w 5 200 || { echo "Cannot acquire map lock"; exit 1; }
    printf "%s\t%s\t%s\t%s\n" "\$symlink_name" "\$port" "\$baud" "\$alias_name" >> "\$MAP_FILE"
  ) 200>"\$MAP_LOCK"
  echo "  ✓ Added to \$MAP_FILE"

  # ---- 3/5. Migrate old ttyUSB entry if exists ----
  # If the device was previously mapped by kernel name, comment it out
  if grep -q "^\${selected_base}\b" "\$MAP_FILE" 2>/dev/null; then
    echo "[3/5] Migrating old kernel-name entry..."
    sed -i "s/^\${selected_base}\t/# migrated to \${symlink_name}: \${selected_base}\t/" "\$MAP_FILE"
    # Stop old service
    systemctl stop "console-lock-bridge@\${selected_base}.service" 2>/dev/null || true
    systemctl disable "console-lock-bridge@\${selected_base}.service" 2>/dev/null || true
    rm -rf "/etc/systemd/system/console-lock-bridge@\${selected_base}.service.d" 2>/dev/null || true
    echo "  ✓ Migrated old \${selected_base} entry"
  fi

  # ---- 4. Create systemd drop-in and start bridge ----
  echo "[4/5] Creating systemd service..."
  local dropdir="/etc/systemd/system/console-lock-bridge@\${symlink_name}.service.d"
  mkdir -p "\$dropdir"
  cat > "\${dropdir}/10-env.conf" <<DROPEOF
[Service]
Environment=CONSOLE_DEV=/dev/\${symlink_name}
Environment=CONSOLE_BAUD=\${baud}
Environment=LOCAL_CONSOLE_PORT=\${port}
Environment=IDLE_TIMEOUT_SECONDS=\${IDLE_TIMEOUT_SECONDS}
Environment=MAX_SESSION_SECONDS=\${MAX_SESSION_SECONDS}
DROPEOF

  systemctl daemon-reload
  systemctl enable --now "console-lock-bridge@\${symlink_name}.service" 2>/dev/null || true

  echo "[5/5] Verifying..."
  sleep 1
  if systemctl is-active --quiet "console-lock-bridge@\${symlink_name}.service" 2>/dev/null; then
    echo "  ✓ Bridge running on port \${port}"
  else
    echo "  ⚠ Bridge not active yet (device may not be plugged in)"
  fi

  echo
  echo "✅ Done! Connect with:"
  echo "   consolectl connect \${alias_name}"
  echo "   consolectl connect \${port}"
  echo "   consolectl connect \${symlink_name}"
}

# ======== RMCONSOLE ========
do_rmconsole() {
  [[ "\${EUID}" -eq 0 ]] || { echo "rmconsole needs sudo"; exit 1; }
  local target="\${1:-}"
  [[ -n "\$target" ]] || { echo "Usage: consolectl rmconsole <alias>"; exit 1; }

  local symlink_name="cgw-\${target}"

  echo "Removing console: \$target"

  # 1. Stop and disable bridge
  if systemctl list-units --plain --no-legend "console-lock-bridge@\${symlink_name}.service" 2>/dev/null | grep -q .; then
    systemctl stop "console-lock-bridge@\${symlink_name}.service" 2>/dev/null || true
    systemctl disable "console-lock-bridge@\${symlink_name}.service" 2>/dev/null || true
    echo "  ✓ Bridge stopped"
  fi
  rm -rf "/etc/systemd/system/console-lock-bridge@\${symlink_name}.service.d" 2>/dev/null || true
  systemctl daemon-reload

  # 2. Remove from map.tsv — use awk exact first-field match (safe against regex chars)
  if [[ -f "\$MAP_FILE" ]]; then
    (
      flock -w 5 200 || { echo "Cannot acquire map lock"; exit 1; }
      tmp=\$(mktemp)
      awk -F'\t' -v dev="\$symlink_name" '\$1 != dev' "\$MAP_FILE" > "\$tmp"
      cp "\$tmp" "\$MAP_FILE"
      rm -f "\$tmp"
    ) 200>"\$MAP_LOCK"
    echo "  ✓ Removed from map"
  fi

  # 3. Remove udev rule — exact match on SYMLINK+="<name>" and TAG+="console-gateway"
  if [[ -f "\$UDEV_RULES_FILE" ]]; then
    tmp=\$(mktemp)
    awk -v sym="\$symlink_name" '
      /^#/ { prev = \$0; next }
      index(\$0, "console-gateway") && index(\$0, "SYMLINK+=\"" sym "\"") { prev = ""; next }
      { if (prev != "") print prev; prev = ""; print }
      END { if (prev != "") print prev }
    ' "\$UDEV_RULES_FILE" > "\$tmp"
    cp "\$tmp" "\$UDEV_RULES_FILE"
    rm -f "\$tmp"
    udevadm control --reload-rules
    echo "  ✓ Removed udev rule"
  fi

  # 4. Clean up runtime files
  rm -f "/run/console-gateway.\${symlink_name}.lock" "/run/console-gateway.\${symlink_name}.owner" 2>/dev/null || true

  echo
  echo "✅ Removed: \$target"
}

# ======== LIST ========
list_map() {
  if [[ ! -f "\$MAP_FILE" ]]; then
    echo "No map: \$MAP_FILE"
    exit 1
  fi
  printf "%-24s %-6s %-8s %-20s %-10s %s\n" "DEVICE" "PORT" "BAUD" "ALIAS" "STATUS" "LINK"
  printf '%0.s─' {1..90}; echo
  while IFS=\$'\t' read -r dev port baud alias; do
    [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
    validate_map_dev "\$dev" || continue
    validate_port_number "\$port" || continue

    local status="stopped"
    if systemctl is-active --quiet "console-lock-bridge@\${dev}.service" 2>/dev/null; then
      status="running"
    fi

    local link_target=""
    if [[ -L "/dev/\${dev}" ]]; then
      link_target="-> \$(readlink "/dev/\${dev}")"
    elif [[ -e "/dev/\${dev}" ]]; then
      link_target="(direct)"
    else
      link_target="(missing!)"
      status="no-device"
    fi

    printf "%-24s %-6s %-8s %-20s %-10s %s\n" "\$dev" "\$port" "\$baud" "\${alias:-}" "\$status" "\$link_target"
  done < "\$MAP_FILE"
}

# ======== RESOLVE TARGET ========
resolve_target() {
  local t="\$1"
  if [[ "\$t" =~ ^[0-9]+\$ ]]; then
    echo "\$t"; return 0
  fi
  # Direct device/symlink name
  if validate_map_dev "\$t"; then
    awk -F'\t' -v d="\$t" '\$1==d{print \$2; exit}' "\$MAP_FILE"
    return 0
  fi
  # Try as cgw- prefixed
  if validate_map_dev "cgw-\$t"; then
    awk -F'\t' -v d="cgw-\$t" '\$1==d{print \$2; exit}' "\$MAP_FILE"
    return 0
  fi
  # Alias column
  if validate_alias "\$t"; then
    awk -F'\t' -v a="\$t" '\$4==a{print \$2; exit}' "\$MAP_FILE"
    return 0
  fi
  return 1
}

# ======== RESCAN ========
do_rescan() {
  [[ "\${EUID}" -eq 0 ]] || { echo "rescan needs sudo"; exit 1; }

  declare -A seen
  local maxp=\$PORT_BASE
  if [[ -f "\$MAP_FILE" ]]; then
    while IFS=\$'\t' read -r dev port baud alias; do
      [[ -n "\$dev" && ! "\$dev" =~ ^# ]] || continue
      validate_map_dev "\$dev" || continue
      seen["\$dev"]=1
      # Also mark the resolved kernel device as seen
      if [[ -L "/dev/\$dev" ]]; then
        local resolved="\$(readlink -f "/dev/\$dev")"
        seen["\${resolved##*/}"]=1
      fi
      if validate_port_number "\$port" && (( port >= maxp )); then
        maxp=\$((port + 1))
      fi
    done < "\$MAP_FILE"
  fi
  local nextp=\$maxp
  local new_count=0

  for d in /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "\$d" ]] || continue
    local base="\${d##*/}"
    validate_dev_name "\$base" || continue

    # Skip if already in map (by kernel name or by a symlink pointing to it)
    [[ -n "\${seen[\$base]:-}" ]] && continue

    # Also check if any cgw- symlink points to this device
    local has_symlink=0
    for s in /dev/cgw-*; do
      [[ -e "\$s" ]] || continue
      if [[ "\$(readlink -f "\$s")" == "\$(readlink -f "\$d")" ]]; then
        local sname="\${s##*/}"
        [[ -n "\${seen[\$sname]:-}" ]] && has_symlink=1
        break
      fi
    done
    [[ \$has_symlink -eq 1 ]] && continue

    (
      flock -w 5 200 || { echo "Cannot acquire map lock"; exit 1; }
      printf "%s\t%s\t%s\t%s\n" "\$base" "\$nextp" "\$CONSOLE_BAUD_DEFAULT" "" >> "\$MAP_FILE"
    ) 200>"\$MAP_LOCK"

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
    echo "[new] \${base} -> port \${nextp} (use 'sudo consolectl addconsole' for persistent naming)"
    nextp=\$((nextp + 1))
    new_count=\$((new_count + 1))
  done

  if [[ \$new_count -eq 0 ]]; then
    echo "No new devices found."
  else
    echo "Added \${new_count} new device(s) with kernel names."
    echo "TIP: Run 'sudo consolectl addconsole' to assign persistent aliases."
  fi
}

# ======== MAIN ========
case "\${1:-}" in
  list)        list_map ;;
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
    # Try multiple owner file patterns
    for prefix in "\$dev" "cgw-\$dev"; do
      f="/run/console-gateway.\${prefix}.owner"
      [[ -f "\$f" ]] && { cat "\$f"; exit 0; }
    done
    echo "none"
    ;;
  tail)
    n="\${2:-50}"
    tail -n "\$n" /var/log/console-gateway-sessions.log 2>/dev/null || echo "(no log yet)"
    ;;
  kick)
    [[ "\${EUID}" -eq 0 ]] || { echo "kick needs sudo"; exit 1; }
    [[ -n "\${2:-}" ]] || { usage; exit 1; }
    dev="\$2"
    # Try both direct and cgw- prefixed
    if systemctl is-active --quiet "console-lock-bridge@\${dev}.service" 2>/dev/null; then
      systemctl restart "console-lock-bridge@\${dev}.service"
    elif systemctl is-active --quiet "console-lock-bridge@cgw-\${dev}.service" 2>/dev/null; then
      systemctl restart "console-lock-bridge@cgw-\${dev}.service"
    else
      echo "No active bridge found for: \$dev"
      exit 1
    fi
    echo "Kicked sessions on \${dev}"
    ;;
  addconsole)  do_addconsole ;;
  rmconsole)   do_rmconsole "\${2:-}" ;;
  rescan)      do_rescan ;;
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
    echo "Managed symlinks:"
    ls -la /dev/cgw-* 2>/dev/null || echo "  (none)"
    echo
    list_map 2>/dev/null || echo "(no map)"
    ;;
  *)           usage; exit 1 ;;
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
exec consolectl status
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
rm -f /etc/udev/rules.d/90-console-gateway.rules
rm -f /usr/local/bin/console-lock-bridge
rm -f /usr/local/bin/console-session-handler
rm -f /usr/local/bin/consolectl
rm -f /usr/local/bin/console-healthcheck
rm -f /usr/local/bin/console
rm -f /usr/local/bin/console-detect
rm -f /usr/local/bin/console-port
rm -f /run/console-gateway.*.lock /run/console-gateway.*.owner
rm -f /usr/local/bin/console-gateway-uninstall

udevadm control --reload-rules 2>/dev/null || true

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
echo "Done. Check UFW: ufw status verbose"
echo "Note: Tailscale and UFW rules were not removed."
echo "Note: /dev/cgw-* symlinks will disappear after udev reload."
EOF
  chmod +x /usr/local/bin/console-gateway-uninstall
}

post_notes() {
  INSTALL_STAGE=""

  cat <<EOF

✅ Console Gateway v2.9 installed (multi-port, exclusive, persistent naming)

1) Plug USB-serial adapters and scan:
   console-detect                      # shows devices + USB attributes
   consolectl list                     # shows current map + status

2) Add adapters with persistent naming (RECOMMENDED):
   sudo consolectl addconsole          # interactive wizard
   # Creates udev rule + symlink + map entry + starts bridge
   # Example: /dev/cgw-SW-CORE-01 -> /dev/ttyUSB0

3) Start Tailscale:
   sudo tailscale up
   tailscale ip -4

4) Remote access (from supporter's laptop):
   ssh -L 2001:localhost:2001 ${SUPPORT_USER}@<PI_TAILSCALE_IP>
   consolectl connect SW-CORE-01       # by alias
   consolectl connect 2001             # by port

5) Operations:
   consolectl list                     # all ports + status + symlink targets
   consolectl owner SW-CORE-01         # who holds the lock
   consolectl tail                     # recent session log
   consolectl status                   # SSH, Tailscale, bridges health
   sudo consolectl kick SW-CORE-01     # force-disconnect
   sudo consolectl rescan              # quick-add (kernel names, no persistence)
   sudo consolectl rmconsole SW-CORE-01 # remove adapter completely

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
  setup_udev_rules
  generate_mapping
  apply_instances_from_map
  install_logrotate
  install_consolectl
  install_healthcheck
  create_uninstall
  post_notes
}

main "$@"
