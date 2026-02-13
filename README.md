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
│  ┌─────────────────────┐    ┌──────────────────────┐     │
│  │ socat bridge :2001  │───▶│ /dev/ttyUSB0 (9600)  │──┐  │
│  │ flock exclusive     │    └──────────────────────┘  │  │
│  └─────────────────────┘                              │  │
│  ┌─────────────────────┐    ┌──────────────────────┐  │  │
│  │ socat bridge :2002  │───▶│ /dev/ttyUSB1 (9600)  │──┤  │
│  │ flock exclusive     │    └──────────────────────┘  │  │
│  └─────────────────────┘                              │  │
└───────────────────────────────────────────────────────┤──┘
                                                        │
               ┌────────────────────────────────────────┘
               ▼
     ┌──────────────────┐   ┌──────────────────┐
     │ Cisco Switch      │   │ Cisco Router      │
     │ Console Port      │   │ Console Port      │
     └──────────────────┘   └──────────────────┘
```

## Features

- **Exclusive per-port locking** — `flock`-based; second user gets a `[busy]` message instead of garbled output
- **Multi-port support** — auto-detects all USB-serial adapters, assigns each a unique TCP port
- **Tailscale VPN** — zero-config mesh networking, no port forwarding needed
- **SSH hardened** — key-only auth, no root login, restricted to support user
- **Device aliasing** — name ports like `SW-CORE-01` instead of `ttyUSB0`
- **Session logging** — who connected, when, from where
- **Hot-plug rescan** — `consolectl rescan` picks up newly plugged adapters
- **Idle & max timeout** — auto-disconnect inactive or long-running sessions
- **systemd managed** — template units with per-device drop-in overrides
- **One-command uninstall** — clean removal of all components

## Requirements

- Debian/Ubuntu (tested on Raspberry Pi OS Bookworm)
- One or more USB-to-serial adapters (FTDI, Prolific, CH340, CP210x, etc.)
- Root access for installation

## Quick Start

```bash
# 1. Install
sudo bash console-gateway-install.sh

# 2. Add your SSH public key
sudo nano /home/support/.ssh/authorized_keys

# 3. Authenticate Tailscale
sudo tailscale up
tailscale ip -4   # note the IP

# 4. Plug USB-serial adapters and verify
console-detect
consolectl list
```

## Remote Access (from your laptop)

```bash
# SSH tunnel to the Pi (port 2001 = first serial device)
ssh -L 2001:localhost:2001 support@100.x.x.x

# In another terminal, connect to the console
consolectl connect 2001
# or by device name
consolectl connect ttyUSB0
# or by alias
consolectl connect SW-CORE-01
```

Alternatively, use plain `telnet` or `socat` on the tunneled port:

```bash
telnet localhost 2001
# or
socat - TCP:localhost:2001
```

## Configuration

### Environment Variables

Override defaults before running the installer:

| Variable | Default | Description |
|----------|---------|-------------|
| `SUPPORT_USER` | `support` | Linux user for SSH access |
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
# dev        port    baud    alias
ttyUSB0      2001    9600    SW-CORE-01
ttyUSB1      2002    9600    RTR-WAN-01
ttyACM0      2003    115200  FW-EDGE-01
```

After editing, apply changes:

```bash
sudo systemctl daemon-reload
sudo consolectl rescan
```

Alias rules: alphanumeric characters, hyphens, and underscores only (max 64 characters).

### Installer Flags

```bash
sudo bash console-gateway-install.sh --no-ufw-reset   # preserve existing UFW rules
sudo bash console-gateway-install.sh --help
```

## Operations

### consolectl

The main CLI tool for day-to-day operations:

```bash
consolectl list                        # show all ports, status, aliases
consolectl connect <alias|dev|port>    # connect to a console
consolectl owner ttyUSB0               # who currently holds the lock
consolectl tail 100                    # last 100 session log entries
consolectl status                      # SSH, Tailscale, bridge health

sudo consolectl kick ttyUSB0           # force-disconnect active session
sudo consolectl rescan                 # detect new devices, start bridges
```

### Locking Behavior

When a user connects to a port, `flock` acquires an exclusive lock on that device:

- **First user** → gets the console, sees `[ok] Locked ttyUSB0 by 127.0.0.1`
- **Second user** → immediately gets `[busy] Console is in use for ttyUSB0. Try later.`
- **Kick** → `sudo consolectl kick ttyUSB0` restarts the bridge, releasing the lock

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
├── consolectl                   # CLI management tool
├── console-detect               # list USB-serial devices
├── console-healthcheck          # health check script
├── console                      # direct screen access (with conflict warning)
└── console-gateway-uninstall    # clean removal

/etc/console-gateway/
└── map.tsv                      # device → port → baud → alias mapping

/etc/systemd/system/
├── console-lock-bridge@.service              # systemd template unit
└── console-lock-bridge@ttyUSB0.service.d/
    └── 10-env.conf                           # per-device environment override

/var/log/
├── console-gateway-sessions.log  # session audit log (logrotated weekly)
└── console-gateway-install.log   # installer log (logrotated monthly)
```

## Uninstall

```bash
sudo console-gateway-uninstall
```

This removes all bridge services, systemd units, scripts, and config files. Tailscale and UFW rules are preserved.

## Troubleshooting

**No serial devices detected:**
```bash
console-detect          # check USB devices
lsusb                   # verify adapter is recognized
dmesg | tail -20        # check kernel messages
```

**Bridge not starting:**
```bash
systemctl status console-lock-bridge@ttyUSB0
journalctl -u console-lock-bridge@ttyUSB0 -f
```

**Permission denied on serial device:**
```bash
# Ensure support user is in dialout group
groups support
sudo usermod -aG dialout support
```

**Port already in use:**
```bash
ss -tlnp | grep 2001   # check what's using the port
```

## License

MIT

## Contributing

Issues and pull requests welcome. For major changes, please open an issue first to discuss what you'd like to change.
