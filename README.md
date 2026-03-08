# console-gateway

Multi-port exclusive console server for Raspberry Pi — remote access to Cisco/network device serial consoles via Tailscale VPN, SSH tunneling, and socat with flock-based session locking.

## Overview

**console-gateway** turns a Raspberry Pi (or any Debian/Ubuntu box) into a secure, multi-port serial console server. Plug in USB-to-serial adapters, run the installer, and your team can remotely access network equipment consoles over Tailscale VPN — one user per port, no conflicts.

```
┌──────────────────────────────────────────────────────────┐
│  Remote Engineer                                         │
│  ssh -L 2001:localhost:2001 support@<tailscale-ip>       │
│  consolectl connect SW-CORE-01                           │
└──────────────┬───────────────────────────────────────────┘
               │ Tailscale VPN
┌──────────────▼───────────────────────────────────────────┐
│  Raspberry Pi (console-gateway)                          │
│                                                          │
│  ┌─────────────────────────┐  ┌──────────────────────┐   │
│  │ socat bridge :2001      │─▶│ /dev/cgw-SW-CORE-01  │─┐ │
│  │ flock exclusive         │  │ (-> /dev/ttyUSB0)    │ │ │
│  └─────────────────────────┘  └──────────────────────┘ │ │
│  ┌─────────────────────────┐  ┌──────────────────────┐ │ │
│  │ socat bridge :2002      │─▶│ /dev/cgw-RTR-WAN-01  │─┤ │
│  │ flock exclusive         │  │ (-> /dev/ttyUSB1)    │ │ │
│  └─────────────────────────┘  └──────────────────────┘ │ │
│                                                        │ │
│  udev rules: persistent /dev/cgw-* symlinks            │ │
│  map.tsv: symlink → port → baud → alias                │ │
└────────────────────────────────────────────────────────┤─┘
                                                         │
               ┌─────────────────────────────────────────┘
               ▼
     ┌──────────────────┐   ┌──────────────────┐
     │ Cisco Switch      │   │ Cisco Router      │
     │ Console Port      │   │ Console Port      │
     └──────────────────┘   └──────────────────┘
```

## Features

- **Exclusive per-port locking** — `flock`-based; second user gets a `[busy]` message instead of garbled output
- **Persistent device naming** — udev rules create stable `/dev/cgw-<alias>` symlinks based on USB adapter attributes (vendor/product/serial); survives reboot, re-plug, and port swaps
- **Interactive setup wizard** — `consolectl addconsole` walks you through alias + baud + udev rule creation
- **Multi-port support** — auto-detects all USB-serial adapters, assigns each a unique TCP port
- **Tailscale VPN** — zero-config mesh networking, no port forwarding needed
- **SSH hardened** — key-only auth, no root login, restricted to support user
- **Session logging** — who connected, when, from where
- **Hot-plug rescan** — `consolectl rescan` picks up newly plugged adapters
- **Idle & max timeout** — auto-disconnect inactive or long-running sessions
- **systemd managed** — template units with per-device drop-in overrides
- **One-command uninstall** — clean removal of all components
- **Web management UI** — optional browser-based dashboard with web terminal, port management, Tailscale control, and session logs
- **iPhone USB gateway** — plug iPhone USB for out-of-band internet; auto-detect switches eth0 to DHCP server + NAT, unplug restores original config

## Requirements

- Debian/Ubuntu (tested on Raspberry Pi OS Bookworm)
- One or more USB-to-serial adapters (FTDI, Prolific, CH340, CP210x, etc.)
- Root access for installation

## Quick Start

```bash
# 1. Install
sudo bash console-gateway-v2.9-install.sh

# 2. Add your SSH public key
sudo nano /home/support/.ssh/authorized_keys

# 3. Plug USB-serial adapters and add with persistent naming
console-detect                      # see devices + USB attributes
sudo consolectl addconsole          # interactive wizard per adapter

# 4. Authenticate Tailscale
sudo tailscale up
tailscale ip -4   # note the IP

# 5. Verify
consolectl list
```

## Persistent Device Naming

The biggest operational risk with USB-serial adapters is **device name drift** — `/dev/ttyUSB0` might become `/dev/ttyUSB1` after a reboot or re-plug. console-gateway solves this with udev rules.

### How it works

When you run `sudo consolectl addconsole`, the wizard:

1. Reads the adapter's USB attributes (`idVendor`, `idProduct`, `serial`)
2. Creates a udev rule in `/etc/udev/rules.d/90-console-gateway.rules`
3. This produces a stable symlink like `/dev/cgw-SW-CORE-01` → `/dev/ttyUSB0`
4. The map and bridge reference the symlink, not the kernel name

```
# Example udev rule (auto-generated) — single-port adapter
SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6001", \
  ENV{ID_USB_SERIAL_SHORT}=="AB81ADGV", SYMLINK+="cgw-SW-CORE-01", TAG+="console-gateway"

# Example udev rule — multi-port adapter (e.g. FTDI FT4232H), per-port distinction
SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6011", \
  ENV{ID_USB_SERIAL_SHORT}=="FT6LBZ6", ENV{ID_USB_INTERFACE_NUM}=="00", \
  SYMLINK+="cgw-PORT1", TAG+="console-gateway"
```

### Adapter serial numbers

For best results, use adapters with **unique serial numbers** (most FTDI-based adapters have them). The wizard will warn you if an adapter lacks a serial number — in that case, the rule matches by vendor/product ID only, which means all identical adapters share the same rule.

### Multi-port adapters (e.g. FTDI FT4232H)

Multi-port USB-serial adapters expose multiple ports that share the same vendor/product/serial attributes. The `addconsole` wizard automatically detects this and includes `ENV{ID_USB_INTERFACE_NUM}` in the udev rule to distinguish each port individually.

> **Technical note:** v2.9 uses `ENV{ID_USB_*}` properties instead of `ATTRS{}` for udev rules. `ATTRS{}` can only match attributes from a single parent device in the sysfs tree — on multi-port adapters, `bInterfaceNumber` and `serial` reside at different parent levels, causing `ATTRS{}`-based rules to silently fail.

```bash
# Check your adapters
console-detect

# Example output (multi-port FTDI FT4232H):
#   ttyUSB0      -> cgw-PORT1
#     Manufacturer: FTDI
#     Product:      FT4232H Quad HS USB-UART/FIFO IC
#     Vendor ID:    0403
#     Product ID:   6011
#     Serial:       FT6LBZ6
#     Interface:    00
#     Uniqueness:   ✓ Has serial number (ideal for udev rule)
```

## Remote Access

```bash
# SSH tunnel to the Pi (port 2001 = first serial device)
ssh -L 2001:localhost:2001 support@100.x.x.x

# In another terminal, connect by alias, device, or port
consolectl connect SW-CORE-01
consolectl connect cgw-SW-CORE-01
consolectl connect 2001
```

Alternatively, use plain `telnet` or `socat` on the tunneled port:

```bash
telnet localhost 2001
socat - TCP:localhost:2001
```

## Configuration

### Environment Variables

Override defaults before running the installer:

| Variable | Default | Description |
|----------|---------|-------------|
| `SUPPORT_USER` | `support` | Linux user for SSH access |
| `ADMIN_USER` | `$SUDO_USER` | Admin user to include in SSH AllowUsers (auto-detected) |
| `ALLOW_SSH_PORT` | `22` | SSH port |
| `TAILSCALE_ONLY` | `0` | Set to `1` to restrict SSH to Tailscale interface only |
| `PORT_BASE` | `2001` | First TCP port for serial bridges |
| `CONSOLE_BAUD_DEFAULT` | `9600` | Default baud rate |
| `IDLE_TIMEOUT_SECONDS` | `900` | Disconnect after 15 min inactivity |
| `MAX_SESSION_SECONDS` | `3600` | Hard session limit (1 hour) |

Example:

```bash
sudo TAILSCALE_ONLY=1 PORT_BASE=3001 CONSOLE_BAUD_DEFAULT=115200 bash console-gateway-install.sh
```

### Device Map

The device-to-port mapping lives in `/etc/console-gateway/map.tsv`:

```
# device             port    baud    alias
cgw-SW-CORE-01       2001    9600    SW-CORE-01
cgw-RTR-WAN-01       2002    9600    RTR-WAN-01
cgw-FW-EDGE-01       2003    115200  FW-EDGE-01
```

Devices prefixed with `cgw-` are managed symlinks (persistent). Devices like `ttyUSB0` are kernel names (may drift). Use `sudo consolectl addconsole` to upgrade kernel-name entries to persistent symlinks.

### Installer Flags

```bash
sudo bash console-gateway-v2.9-install.sh --ufw-reset   # reset all UFW rules before configuring (destructive)
sudo bash console-gateway-v2.9-install.sh --help
```

## Operations

### consolectl

```bash
# Day-to-day
consolectl list                        # all ports, status, symlink targets
consolectl connect <alias|dev|port>    # connect to a console
consolectl owner SW-CORE-01            # who currently holds the lock
consolectl tail 100                    # last 100 session log entries
consolectl status                      # SSH, Tailscale, bridge health

# Administration (requires sudo)
sudo consolectl addconsole             # interactive: add adapter + persistent naming
sudo consolectl rmconsole SW-CORE-01   # remove adapter, udev rule, bridge
sudo consolectl kick SW-CORE-01        # force-disconnect active session
sudo consolectl rescan                 # quick-add new devices (kernel names)
```

### addconsole Workflow

```
$ sudo consolectl addconsole

=== Console Gateway - Add Console Adapter ===

Scanning for serial devices...

Available devices:

  [1] ttyUSB0       FTDI FT232R USB UART  (S/N: AB81ADGV)
  [2] ttyUSB1       Prolific PL2303       (S/N: none)

Select device number [1-2]: 1

Selected: /dev/ttyUSB0
USB attributes:
  Vendor:  0403 (FTDI)
  Product: 6001 (FT232R USB UART)
  Serial:  AB81ADGV

Alias name (e.g. SW-CORE-01, RTR-WAN-01): SW-CORE-01
Baud rate [9600]: 9600

Assigned port: 2001

┌─────────────────────────────────────────────┐
│  Summary                                    │
├─────────────────────────────────────────────┤
│  Device:    ttyUSB0                         │
│  Alias:     SW-CORE-01                      │
│  Symlink:   /dev/cgw-SW-CORE-01             │
│  Port:      2001                            │
│  Baud:      9600                            │
│  Vendor:    0403:6001                       │
│  Serial:    AB81ADGV                        │
└─────────────────────────────────────────────┘

Apply these settings? (Y/n): y

[1/4] Creating udev rule...
  ✓ Symlink /dev/cgw-SW-CORE-01 -> /dev/ttyUSB0
[2/4] Updating map...
  ✓ Added to /etc/console-gateway/map.tsv
[3/4] Creating systemd service...
[4/4] Verifying...
  ✓ Bridge running on port 2001

✅ Done! Connect with:
   consolectl connect SW-CORE-01
```

### Locking Behavior

When a user connects to a port, `flock` acquires an exclusive lock:

- **First user** → gets the console, sees `[ok] Locked cgw-SW-CORE-01 by 127.0.0.1`
- **Second user** → immediately gets `[busy] Console is in use for cgw-SW-CORE-01. Try later.`
- **Kick** → `sudo consolectl kick SW-CORE-01` restarts the bridge, releasing the lock

### Tailscale-Only Mode

For maximum security, restrict SSH to the Tailscale interface:

```bash
# After 'sudo tailscale up':
sudo ufw delete allow 22/tcp
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw status verbose
```

## File Layout

```
/usr/local/bin/
├── console-lock-bridge          # socat bridge launcher (per-device)
├── console-session-handler      # per-connection session logic (flock + serial)
├── consolectl                   # CLI management tool (list/connect/addconsole/...)
├── console-detect               # list USB-serial devices with attributes
├── console-healthcheck          # health check (delegates to consolectl status)
├── console                      # direct screen access (with conflict warning)
└── console-gateway-uninstall    # clean removal

/etc/console-gateway/
└── map.tsv                      # device → port → baud → alias mapping

/etc/udev/rules.d/
└── 90-console-gateway.rules     # persistent USB-serial symlink rules

/etc/systemd/system/
├── console-lock-bridge@.service                   # systemd template unit
└── console-lock-bridge@cgw-SW-CORE-01.service.d/
    └── 10-env.conf                                # per-device environment

/var/log/
├── console-gateway-sessions.log  # session audit log (logrotated weekly)
└── console-gateway-install.log   # installer log (logrotated monthly)

/dev/
├── cgw-SW-CORE-01 -> ttyUSB0    # persistent symlink (udev-managed)
└── cgw-RTR-WAN-01 -> ttyUSB1    # persistent symlink (udev-managed)

/usr/local/sbin/
├── cgw-iphone-up                  # iPhone gateway activate (udev/manual)
└── cgw-iphone-down                # iPhone gateway deactivate (udev/manual)

/etc/udev/rules.d/
└── 99-cgw-iphone.rules            # auto-detect iPhone USB plug/unplug

/run/
└── cgw-network.state              # current network mode (normal/iphone-gw)

/opt/console-gateway-web/          # (optional) web management UI
├── app.py                         # Flask + SocketIO application
├── venv/                          # Python virtual environment
├── templates/
│   ├── login.html
│   └── dashboard.html
└── uninstall.sh
```

## Comparison with ConsolePi

| Feature | console-gateway | ConsolePi |
|---------|----------------|-----------|
| Serial daemon | socat + flock | ser2net |
| Exclusive locking | ✅ Built-in | ❌ Not supported |
| Persistent naming | ✅ udev + cgw- symlinks | ✅ udev + custom symlinks |
| Remote access | Tailscale + SSH tunnel | OpenVPN + Telnet/SSH |
| Multi-Pi cluster | Single node | ✅ Google Drive / mDNS |
| Power control | — | GPIO / espHome / Tasmota / DLI |
| TUI menu | CLI only | ✅ curses-style menu |
| ZTP orchestration | — | ✅ Built-in |
| Install complexity | Single shell script | Python + many dependencies |
| Code size | ~1,300 lines bash | ~15,000+ lines Python + bash |

console-gateway is designed for teams that need a **simple, secure, conflict-free** console server with minimal dependencies. ConsolePi is a better fit if you need multi-Pi clustering, power outlet control, or a full TUI experience.

## Web Management UI

A browser-based management interface is available as an optional add-on. Install it on top of an existing Console Gateway setup.

### Web UI Features

- **Dashboard** — real-time port status (running/stopped/busy), SSH & Tailscale health overview
- **Web Terminal** — connect to serial consoles directly from the browser (xterm.js + WebSocket)
- **Port Management** — start/stop/restart/kick/unlock ports, edit aliases — all from the UI
- **Network / iPhone Gateway** — interface status, iPhone USB auto-detect, gateway mode control
- **Tailscale Management** — connect/disconnect, view peers, ping, QR code for mobile authentication
- **Session Log** — browse connection history
- **Settings** — per-port baud/timeout overrides, global defaults

```
┌──────────────────────────────────────────────────────────────────┐
│  Browser  http://<pi-ip>:8080                                    │
│  ┌─────┐ ┌──────────┐ ┌─────────┐ ┌───────────┐ ┌────┐ ┌────┐  │
│  │Ports│ │ Terminal  │ │ Network │ │ Tailscale │ │Logs│ │Cfg │  │
│  └──┬──┘ └────┬─────┘ └────┬────┘ └─────┬─────┘ └──┬─┘ └──┬─┘  │
│     ▼         ▼            ▼             ▼          ▼      ▼    │
│  map.tsv   WebSocket   iphone-gw     tailscale   log   settings │
│  systemctl  :200x      udev/NAT      CLI         tail  drop-in │
└──────────────────────────────────────────────────────────────────┘
```

### Install Web UI

```bash
# Default: port 8080, login admin/consolegateway
sudo bash console-gateway-web-install.sh

# Custom settings
sudo bash console-gateway-web-install.sh --port 9090 --password mypassword

# Or install directly from GitHub
curl -sL https://raw.githubusercontent.com/alan-sun-dev/rpi-serial-console-gateway/main/console-gateway-web-install.sh | sudo bash
```

### Web UI Options

| Option | Default | Description |
|--------|---------|-------------|
| `--port` | `8080` | Web server port |
| `--password` | `consolegateway` | Admin password |
| `--user` | `admin` | Admin username |
| `--host` | `0.0.0.0` | Listen address |
| `--dir` | `/opt/console-gateway-web` | Install directory |

### Web UI Service

```bash
sudo systemctl status console-gateway-web    # check status
sudo systemctl restart console-gateway-web   # restart
sudo systemctl stop console-gateway-web      # stop

# Change password (generates werkzeug pbkdf2 salted hash)
NEW_HASH=$(/opt/console-gateway-web/venv/bin/python3 -c \
  "from werkzeug.security import generate_password_hash; \
   import getpass; print(generate_password_hash(getpass.getpass()))")
sudo systemctl edit console-gateway-web
# Add: Environment=CGW_ADMIN_PASS_HASH=<paste hash>
sudo systemctl restart console-gateway-web

# Uninstall
sudo /opt/console-gateway-web/uninstall.sh
```

### Web UI Tech Stack

- **Backend:** Python Flask + Flask-SocketIO (eventlet)
- **Frontend:** Bootstrap 5 + xterm.js + socket.io + qrcode-generator
- **Auth:** werkzeug pbkdf2 password hash, session-based login, CSRF token protection
- **Install:** Python venv in `/opt/console-gateway-web/`, systemd managed

## iPhone USB Gateway (Out-of-Band)

When working at remote sites without reliable network access, you can use an iPhone as an out-of-band internet uplink via USB tethering. The web installer sets up **automatic plug/unplug detection** — no manual configuration needed.

### How It Works

```
iPhone plugged in (USB)                    iPhone unplugged
        │                                         │
   udev trigger                               udev trigger
        │                                         │
   cgw-iphone-up                            cgw-iphone-down
        │                                         │
   ┌────▼─────────────────────┐          ┌────────▼──────────────┐
   │ 1. Detect usb0/enx*     │          │ 1. Stop dnsmasq       │
   │ 2. Backup eth0 config   │          │ 2. Remove NAT rules   │
   │ 3. idevicepair pair     │          │ 3. Restore eth0       │
   │ 4. eth0 → 192.168.88.1  │          │    (NM / dhcpcd /     │
   │    DHCP server active   │          │     manual fallback)  │
   │ 5. nftables NAT         │          └───────────────────────┘
   │    iPhone USB = WAN     │
   └─────────────────────────┘

   Mode: iPhone Gateway                  Mode: Normal
   eth0: 192.168.88.1 (LAN/DHCP)         eth0: original config
   usb0: iPhone hotspot (WAN)             usb0: (gone)
   Other devices on eth0 get internet     Tailscale reconnects via eth0/WiFi
```

### Usage

1. **Connect iPhone** to Pi via USB cable
2. **Enable Personal Hotspot** on iPhone (Settings > Personal Hotspot)
3. **First time only:** tap "Trust This Computer" on iPhone
4. Gateway mode activates automatically — eth0 becomes a DHCP server (192.168.88.0/24), other devices on eth0 get internet via iPhone
5. **Unplug iPhone** — eth0 reverts to its previous config automatically

### Network Modes

| Mode | WAN (Internet) | eth0 Role | Use Case |
|------|---------------|-----------|----------|
| Normal (DHCP) | eth0 via site network | DHCP client | Site has working network |
| Normal (WiFi) | wlan0 | DHCP client or unused | Use Pi's WiFi for internet |
| iPhone Gateway | iPhone USB (usb0) | **DHCP server** (192.168.88.0/24) | Out-of-band / no site network |

### Web UI Control

The **Network** tab in the web UI shows:
- Current mode indicator (Normal / iPhone Gateway)
- All network interfaces with IPs and link state
- Default route
- iPhone detection and pairing status
- Manual **Enable Gateway** / **Disable Gateway** / **Pair iPhone** buttons

### Troubleshooting iPhone Gateway

```bash
# Check current mode
cat /run/cgw-network.state

# Watch auto-detect logs
journalctl -t cgw-iphone -f

# Manual activate/deactivate
sudo /usr/local/sbin/cgw-iphone-up
sudo /usr/local/sbin/cgw-iphone-down

# Check iPhone pairing
idevicepair validate

# Check if udev rules are loaded
udevadm info /sys/class/net/usb0    # when iPhone is plugged in
```

## Uninstall

```bash
sudo console-gateway-uninstall
```

Removes all bridge services, systemd units, scripts, udev rules, and config files. Tailscale and UFW rules are preserved.

## Troubleshooting

**No serial devices detected:**
```bash
console-detect          # check USB devices and attributes
lsusb                   # verify adapter is recognized
dmesg | tail -20        # check kernel messages
```

**Symlink not appearing after addconsole:**
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=tty
ls -la /dev/cgw-*
```

**Bridge not starting:**
```bash
systemctl status console-lock-bridge@cgw-SW-CORE-01
journalctl -u console-lock-bridge@cgw-SW-CORE-01 -f
```

**Device name drifted (ttyUSB0 became ttyUSB1):**
```bash
# This is exactly why persistent naming exists. Migrate:
sudo consolectl addconsole    # re-add with udev rule
# The cgw- symlink always points to the right device
```

**Multi-port adapter: all ports get the same symlink or symlinks don't appear:**
```bash
# Verify your udev rules use ENV{} (not ATTRS{}) and include ID_USB_INTERFACE_NUM:
cat /etc/udev/rules.d/90-console-gateway.rules
# Correct rule should look like:
#   SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6011", \
#     ENV{ID_USB_SERIAL_SHORT}=="FT6LBZ6", ENV{ID_USB_INTERFACE_NUM}=="00", ...
# If rules use ATTRS{}, re-run addconsole with v2.6 to regenerate them.
```

**Permission denied on serial device:**
```bash
groups support
sudo usermod -aG dialout support
```

## License

MIT

## Contributing

Issues and pull requests welcome. For major changes, please open an issue first to discuss.
