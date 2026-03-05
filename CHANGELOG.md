# Changelog

## v2.8 (2026-03-05)

Merged findings from two independent code reviews.

### Security

- **BAUD injection guard** — `console-lock-bridge` and `console-session-handler` now
  validate that `$BAUD` and `$PORT` are strictly numeric before passing to socat's
  address spec. Previously, a malicious environment value like `9600,exec:'...'` could
  exploit socat's address parser.
- **systemd service sandboxing** — bridge services now run with `NoNewPrivileges=yes`,
  `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and
  `RestrictAddressFamilies=AF_INET AF_UNIX`. Even though the listener is bound to
  127.0.0.1, defense-in-depth applies.
- **UFW reset is now opt-in** — previously defaulted to `--no-ufw-reset` to skip reset,
  meaning the default was destructive. Flipped to safe-by-default: existing rules are
  preserved unless `--ufw-reset` is explicitly passed.

### Bug Fixes

- **`rmconsole` awk uses exact `SYMLINK+="name"` match** — previously used
  `index($0, sym)` which would match `cgw-SW1` when removing `cgw-SW10` (substring
  collision). Now requires the full `SYMLINK+="cgw-SW1"` string to match.
- **Session handler cleans up owner file on exit** — added `trap cleanup EXIT INT TERM`
  to remove `/run/console-gateway.${BASE}.owner` when session ends. Previously the
  owner file could persist after abnormal exit, showing stale session info.
- **Tailscale repo detection supports Debian and Ubuntu** — `install_tailscale()` was
  hardcoded to `debian/` repo path. Ubuntu codenames (e.g. `jammy`) don't exist under
  that path. Now detects distro family from `/etc/os-release`.
- **`ss` port check uses strict pattern** — `grep ":${port} "` could false-match
  (port 200 matching `:2001 `). Now uses `ss -tlnp sport = :${port}` for exact match.
- **`generate_mapping()` checks port conflicts at bootstrap** — initial auto-detect
  used `PORT_BASE + i` without checking if ports were already bound. Now uses the
  same `ss` check as `next_available_port()`.
- **`rmconsole` map.tsv uses awk exact field match** — replaced `grep -v` (regex-based,
  `-` has special meaning in character classes) with `awk -F'\t' '$1 != dev'` for
  safe exact first-field comparison.
- **Uninstall script removes itself** — previously left
  `/usr/local/bin/console-gateway-uninstall` behind after uninstall.

### Cleanup

- Removed unused `net-tools` from package dependencies (already have `iproute2`).

---

## v2.7 (2026-03-05)

### Security

- **Tailscale install switched from `curl | sh` to official apt repo** — eliminates
  supply-chain risk from DNS hijacking or CDN compromise when piping remote scripts
  directly into a root shell.

### Bug Fixes

- **`CONSOLE_BAUD_DEFAULT` now validated at startup** — previously, an invalid value
  (e.g. `export CONSOLE_BAUD_DEFAULT=99999`) would pass `validate_basic()` unchecked
  and propagate into map.tsv and systemd drop-ins, only failing at socat connect time.
- **Removed `local` misuse inside subshells** — `local` inside a `( ... )` subshell
  is semantically meaningless (subshell is a separate process). Fixed in `do_rmconsole`.
- **Removed dead code `map_locked_append()`** — defined but never called; `generate_mapping()`
  wrote directly with `>>` without locking. Removed to avoid confusion.
- **`next_available_port()` now checks OS-level port conflicts** — previously only
  scanned map.tsv; now uses `ss -tlnp` to skip ports already bound by other services.
- **Summary box truncates long alias names** — alias can be up to 60 chars but the box
  column was 32 wide, causing `│` border misalignment. Now uses `%.32s` truncation.
- **Removed unused `jq` from package install** — was listed in `apt-get install` but
  never used anywhere in the codebase.
- **systemd template uses `BindsTo=dev-%i.device`** — previously only had
  `After=network.target` (which is irrelevant for serial bridges). Without device
  binding, systemd would endlessly restart the bridge when the device was unplugged,
  flooding the journal with restart logs.
- **`addconsole` step labels corrected** — was `[1/4]`..`[4/4]` but the "migrate old
  entry" step had no label, making step 3 appear to jump. Now correctly `[1/5]`..`[5/5]`.
- **`rmconsole` udev rule removal uses `TAG+"console-gateway"` for matching** —
  previously matched only on symlink name, which could misidentify lines if the
  symlink name appeared in unrelated comments. Now requires both the TAG and
  symlink name to match.

---

## v2.6 (2026-03-05)

### Bug Fixes

#### 1. SSH AllowUsers locks out the installer/admin user

**Problem:**
`harden_ssh()` writes `AllowUsers support` (or whatever `SUPPORT_USER` is set to)
into the sshd drop-in config. If the person running `sudo bash install.sh` is
logged in as a different user (e.g. `alan`, `pi`, `admin`), they are immediately
locked out of SSH after sshd restarts — potentially losing remote access to the
machine entirely.

**Root Cause:**
The SSH hardening step only considered the dedicated support user, not the
system administrator who is actually running the installer.

**Fix:**
Auto-detect `SUDO_USER` (the real user behind `sudo`) and include them in
`AllowUsers` alongside `SUPPORT_USER`. A new `ADMIN_USER` config variable
is available for explicit override.

```
# Before (v2.5)
AllowUsers support

# After (v2.6)
AllowUsers support alan    # alan = auto-detected from SUDO_USER
```

---

#### 2. addconsole udev rules fail on multi-port USB-serial adapters

**Problem:**
`consolectl addconsole` generates udev rules using `ATTRS{}` to match USB
attributes. On multi-port adapters like the FTDI FT4232H (4-port USB-UART),
the symlinks either fail to appear entirely or all 4 ports get the same
symlink — making persistent naming useless.

**Root Cause:**
Udev `ATTRS{}` can only match attributes from **one parent device** in the
sysfs hierarchy. Multi-port adapters have their attributes split across
different parent levels:

```
Parent level 1 (USB interface):  ATTRS{bInterfaceNumber}=="00"
Parent level 2 (USB device):     ATTRS{serial}=="FT6LBZ6"
```

A rule like `ATTRS{serial}=="FT6LBZ6", ATTRS{bInterfaceNumber}=="00"` silently
fails because these attributes are on different parents. Without `bInterfaceNumber`,
a rule matching only `serial` applies to ALL ports of the adapter identically.

**Fix:**
Switch from `ATTRS{}` (sysfs attribute walk) to `ENV{ID_USB_*}` (udev device
properties). These properties are flattened by udev's built-in USB handler and
can be freely combined in a single rule:

```
# Before (v2.5) — ATTRS{} from different parents, silently fails
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6011", ATTRS{serial}=="FT6LBZ6", SYMLINK+="cgw-PORT1"

# After (v2.6) — ENV{} properties, all combinable
SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6011", ENV{ID_USB_SERIAL_SHORT}=="FT6LBZ6", ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="cgw-PORT1"
```

Additionally, `ENV{ID_USB_INTERFACE_NUM}` is now always included when available,
so each port on a multi-port adapter gets its own distinct symlink.

---

### Enhancements

- `console-detect` now displays the USB interface number for each device,
  making it easier to identify individual ports on multi-port adapters.
- `addconsole` wizard now detects multi-port adapters (multiple ports sharing
  the same serial number) and informs the user that interface number will be
  used for disambiguation.
- `addconsole` summary box now shows the interface number.

---

## v2.5

- udev persistent naming: adapters get stable symlinks based on USB attributes
  (vendor/product/serial), survives reboot and re-plug in any port
- Interactive `consolectl addconsole` wizard: plug adapter, set alias + baud,
  auto-generates udev rule + map entry + starts bridge
- `map.tsv` now references stable symlink names (not ttyUSB0)
- `consolectl addconsole` / `rmconsole` for full lifecycle management
- `console-detect` shows USB attributes for each adapter

## v2.4

- Extracted socat session handler (no nested quote hell)
- Strict `map.tsv` field validation
- Fixed systemctl glob restart (explicit unit iteration)
- `consolectl rescan` creates drop-ins and starts new units
- Logrotate, flock on map writes, UFW `--no-ufw-reset`, trap cleanup
