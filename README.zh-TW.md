# console-gateway

Raspberry Pi 多埠獨佔式 Console 伺服器 — 透過 Tailscale VPN、SSH 通道與 socat + flock 鎖定機制，遠端存取 Cisco / 網路設備的 Serial Console。

## 概述

**console-gateway** 將 Raspberry Pi（或任何 Debian/Ubuntu 主機）變成安全的多埠 Serial Console 伺服器。插上 USB 轉 Serial 轉接器、執行安裝腳本，團隊即可透過 Tailscale VPN 遠端存取網路設備 Console — 每個埠一人獨佔，不會互相干擾。

```
┌──────────────────────────────────────────────────────────┐
│  遠端工程師                                                │
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
│  udev rules: 持久化 /dev/cgw-* symlinks                 │ │
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

## 功能特色

- **獨佔式埠鎖定** — 基於 `flock`；第二位使用者會收到 `[busy]` 訊息，而非亂碼輸出
- **持久化裝置命名** — udev 規則根據 USB 轉接器屬性（vendor/product/serial）建立穩定的 `/dev/cgw-<alias>` symlink；重開機、重插、換埠都不受影響
- **互動式設定精靈** — `consolectl addconsole` 引導你完成別名 + 鮑率 + udev 規則建立
- **多埠支援** — 自動偵測所有 USB 轉 Serial 轉接器，各自分配唯一 TCP 埠
- **Tailscale VPN** — 零設定 mesh 網路，無需 port forwarding
- **SSH 安全強化** — 僅允許金鑰認證、禁止 root 登入、限制 support 使用者
- **連線日誌** — 記錄誰在何時從何處連線
- **熱插拔重新掃描** — `consolectl rescan` 偵測新插入的轉接器
- **閒置與最長連線逾時** — 自動中斷閒置或超時的連線
- **systemd 管理** — 樣板 unit 搭配各裝置獨立的 drop-in 覆寫
- **一鍵解除安裝** — 乾淨移除所有元件

## 系統需求

- Debian/Ubuntu（已於 Raspberry Pi OS Bookworm 測試）
- 一或多個 USB 轉 Serial 轉接器（FTDI、Prolific、CH340、CP210x 等）
- 安裝需要 root 權限

## 快速開始

```bash
# 1. 安裝
sudo bash console-gateway-v2.9-install.sh

# 2. 加入你的 SSH 公鑰
sudo nano /home/support/.ssh/authorized_keys

# 3. 插入 USB 轉 Serial 轉接器並建立持久化命名
console-detect                      # 查看裝置與 USB 屬性
sudo consolectl addconsole          # 互動式精靈（逐一設定轉接器）

# 4. 驗證 Tailscale
sudo tailscale up
tailscale ip -4   # 記下 IP 位址

# 5. 確認
consolectl list
```

## 持久化裝置命名

USB 轉 Serial 轉接器最大的操作風險是**裝置名稱漂移** — `/dev/ttyUSB0` 在重開機或重插後可能變成 `/dev/ttyUSB1`。console-gateway 透過 udev 規則解決此問題。

### 運作原理

執行 `sudo consolectl addconsole` 時，精靈會：

1. 讀取轉接器的 USB 屬性（`idVendor`、`idProduct`、`serial`）
2. 在 `/etc/udev/rules.d/90-console-gateway.rules` 建立 udev 規則
3. 產生穩定的 symlink，例如 `/dev/cgw-SW-CORE-01` → `/dev/ttyUSB0`
4. map 與 bridge 都參照 symlink，而非核心裝置名稱

```
# udev 規則範例（自動產生）— 單埠轉接器
SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6001", \
  ENV{ID_USB_SERIAL_SHORT}=="AB81ADGV", SYMLINK+="cgw-SW-CORE-01", TAG+="console-gateway"

# udev 規則範例 — 多埠轉接器（如 FTDI FT4232H），按埠區分
SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6011", \
  ENV{ID_USB_SERIAL_SHORT}=="FT6LBZ6", ENV{ID_USB_INTERFACE_NUM}=="00", \
  SYMLINK+="cgw-PORT1", TAG+="console-gateway"
```

### 轉接器序號

建議使用具有**唯一序號**的轉接器（大多數 FTDI 轉接器都有）。精靈會在轉接器缺少序號時發出警告 — 此時規則僅以 vendor/product ID 比對，代表所有相同型號的轉接器會共用同一條規則。

### 多埠轉接器（如 FTDI FT4232H）

多埠 USB 轉 Serial 轉接器會曝露多個共用相同 vendor/product/serial 屬性的埠。`addconsole` 精靈會自動偵測此情況，並在 udev 規則中加入 `ENV{ID_USB_INTERFACE_NUM}` 以區分各埠。

> **技術說明：** v2.9 使用 `ENV{ID_USB_*}` 屬性而非 `ATTRS{}` 建立 udev 規則。`ATTRS{}` 只能比對 sysfs 樹狀結構中單一父裝置的屬性 — 在多埠轉接器上，`bInterfaceNumber` 和 `serial` 位於不同的父層級，會導致 `ATTRS{}` 規則靜默失敗。

```bash
# 檢查你的轉接器
console-detect

# 範例輸出（多埠 FTDI FT4232H）：
#   ttyUSB0      -> cgw-PORT1
#     Manufacturer: FTDI
#     Product:      FT4232H Quad HS USB-UART/FIFO IC
#     Vendor ID:    0403
#     Product ID:   6011
#     Serial:       FT6LBZ6
#     Interface:    00
#     Uniqueness:   ✓ Has serial number (ideal for udev rule)
```

## 遠端存取

### Linux / macOS

```bash
# 建立 SSH 通道到 Pi（port 2001 = 第一個 serial 裝置）
ssh -L 2001:localhost:2001 support@100.x.x.x

# 在另一個終端機，以別名、裝置或埠號連線
consolectl connect SW-CORE-01
consolectl connect cgw-SW-CORE-01
consolectl connect 2001
```

也可以使用 `telnet` 或 `socat` 連線到轉發的埠：

```bash
telnet localhost 2001
socat - TCP:localhost:2001
```

### Windows

#### 方法一：使用 PuTTY（SSH 通道 + Telnet）

1. **建立 SSH 通道**
   - 開啟 PuTTY，在 **Session** 輸入 Pi 的 Tailscale IP（如 `100.x.x.x`），Port `22`
   - 到 **Connection → SSH → Tunnels**：
     - Source port: `2001`
     - Destination: `localhost:2001`
     - 點選 **Add**
     - 若有多個裝置，重複上述步驟加入 `2002`、`2003` 等
   - 回到 **Session**，可儲存設定方便日後使用，然後點選 **Open** 連線
   - 以 `support` 使用者登入（需已設定 SSH 金鑰）

2. **連線到 Console**
   - 在 SSH 連線的視窗中直接執行：
     ```
     consolectl connect SW-CORE-01
     ```
   - 或者另開一個 PuTTY 視窗，選擇 **Telnet**，連線到 `localhost` port `2001`

#### 方法二：使用 Windows OpenSSH（內建）

Windows 10/11 已內建 OpenSSH 客戶端，可直接在 PowerShell 或 CMD 使用：

```powershell
# 建立 SSH 通道（與 Linux/macOS 用法相同）
ssh -L 2001:localhost:2001 support@100.x.x.x

# 在 SSH 連線中直接使用
consolectl connect SW-CORE-01
```

若要轉發多個埠：

```powershell
ssh -L 2001:localhost:2001 -L 2002:localhost:2002 -L 2003:localhost:2003 support@100.x.x.x
```

然後在另一個 PowerShell 視窗中，用 Telnet 或其他 TCP 客戶端連線：

```powershell
# 啟用 Windows Telnet 用戶端（僅需執行一次，需以系統管理員身分）
dism /online /Enable-Feature /FeatureName:TelnetClient

# 連線到轉發的埠
telnet localhost 2001
```

#### 方法三：使用 SecureCRT / Xshell 等終端工具

大多數商業 SSH 終端工具都支援 SSH Local Port Forwarding，設定方式與 PuTTY 類似：

1. 在連線設定中加入 SSH 通道（Local Port Forward）
2. 將本機埠 `2001` 轉發到 `localhost:2001`
3. 連線後，在 SSH session 中執行 `consolectl connect <alias>`

#### Windows 注意事項

- **SSH 金鑰**：Windows OpenSSH 的金鑰預設存放在 `%USERPROFILE%\.ssh\`（如 `C:\Users\你的帳號\.ssh\id_rsa`）
- **Tailscale**：Windows 版 Tailscale 可從官網下載安裝，安裝後 Pi 的 Tailscale IP 可直接使用
- **跳脫字元**：透過 Telnet 連線時，按 `Ctrl+]` 可回到 Telnet 提示符，輸入 `quit` 離開

## 組態設定

### 環境變數

安裝前可透過環境變數覆寫預設值：

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `SUPPORT_USER` | `support` | SSH 存取的 Linux 使用者 |
| `ADMIN_USER` | `$SUDO_USER` | 納入 SSH AllowUsers 的管理員（自動偵測） |
| `ALLOW_SSH_PORT` | `22` | SSH 埠號 |
| `TAILSCALE_ONLY` | `0` | 設為 `1` 可限制 SSH 僅透過 Tailscale 介面連線 |
| `PORT_BASE` | `2001` | Serial bridge 的起始 TCP 埠號 |
| `CONSOLE_BAUD_DEFAULT` | `9600` | 預設鮑率 |
| `IDLE_TIMEOUT_SECONDS` | `900` | 閒置 15 分鐘後自動中斷 |
| `MAX_SESSION_SECONDS` | `3600` | 最長連線時間限制（1 小時） |

範例：

```bash
sudo TAILSCALE_ONLY=1 PORT_BASE=3001 CONSOLE_BAUD_DEFAULT=115200 bash console-gateway-install.sh
```

### 裝置對應表

裝置與埠的對應關係存放在 `/etc/console-gateway/map.tsv`：

```
# device             port    baud    alias
cgw-SW-CORE-01       2001    9600    SW-CORE-01
cgw-RTR-WAN-01       2002    9600    RTR-WAN-01
cgw-FW-EDGE-01       2003    115200  FW-EDGE-01
```

以 `cgw-` 開頭的是受管理的 symlink（持久化）。像 `ttyUSB0` 這類是核心裝置名稱（可能漂移）。使用 `sudo consolectl addconsole` 可將核心名稱升級為持久化 symlink。

### 安裝旗標

```bash
sudo bash console-gateway-v2.9-install.sh --ufw-reset   # 安裝前重設所有 UFW 規則（破壞性操作）
sudo bash console-gateway-v2.9-install.sh --help
```

## 操作指南

### consolectl

```bash
# 日常操作
consolectl list                        # 所有埠、狀態、symlink 目標
consolectl connect <alias|dev|port>    # 連線到 console
consolectl owner SW-CORE-01            # 查看目前誰持有鎖定
consolectl tail 100                    # 最近 100 筆連線日誌
consolectl status                      # SSH、Tailscale、bridge 健康狀態

# 管理操作（需要 sudo）
sudo consolectl addconsole             # 互動式：新增轉接器 + 持久化命名
sudo consolectl rmconsole SW-CORE-01   # 移除轉接器、udev 規則、bridge
sudo consolectl kick SW-CORE-01        # 強制中斷使用中的連線
sudo consolectl rescan                 # 快速偵測新裝置（核心名稱，無持久化）
```

### addconsole 工作流程

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

Done! Connect with:
   consolectl connect SW-CORE-01
```

### 鎖定行為

當使用者連線到某個埠時，`flock` 會取得獨佔鎖：

- **第一位使用者** → 取得 console，看到 `[ok] Locked cgw-SW-CORE-01 by 127.0.0.1`
- **第二位使用者** → 立即收到 `[busy] Console is in use for cgw-SW-CORE-01. Try later.`
- **踢除** → `sudo consolectl kick SW-CORE-01` 重啟 bridge 以釋放鎖定

### 僅限 Tailscale 模式

若要最大化安全性，可將 SSH 限制為僅透過 Tailscale 介面連線：

```bash
# 執行 'sudo tailscale up' 之後：
sudo ufw delete allow 22/tcp
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw status verbose
```

## 檔案配置

```
/usr/local/bin/
├── console-lock-bridge          # socat bridge 啟動器（每個裝置）
├── console-session-handler      # 每次連線的 session 邏輯（flock + serial）
├── consolectl                   # CLI 管理工具（list/connect/addconsole/...）
├── console-detect               # 列出 USB 轉 Serial 裝置與屬性
├── console-healthcheck          # 健康檢查（委派給 consolectl status）
├── console                      # 直接 screen 存取（含衝突警告）
└── console-gateway-uninstall    # 乾淨移除

/etc/console-gateway/
└── map.tsv                      # 裝置 → 埠 → 鮑率 → 別名 對應表

/etc/udev/rules.d/
└── 90-console-gateway.rules     # 持久化 USB 轉 Serial symlink 規則

/etc/systemd/system/
├── console-lock-bridge@.service                   # systemd 樣板 unit
└── console-lock-bridge@cgw-SW-CORE-01.service.d/
    └── 10-env.conf                                # 各裝置環境設定

/var/log/
├── console-gateway-sessions.log  # 連線稽核日誌（每週輪替）
└── console-gateway-install.log   # 安裝日誌（每月輪替）

/dev/
├── cgw-SW-CORE-01 -> ttyUSB0    # 持久化 symlink（udev 管理）
└── cgw-RTR-WAN-01 -> ttyUSB1    # 持久化 symlink（udev 管理）
```

## 與 ConsolePi 的比較

| 功能 | console-gateway | ConsolePi |
|------|----------------|-----------|
| Serial daemon | socat + flock | ser2net |
| 獨佔鎖定 | 內建 | 不支援 |
| 持久化命名 | udev + cgw- symlinks | udev + 自訂 symlinks |
| 遠端存取 | Tailscale + SSH 通道 | OpenVPN + Telnet/SSH |
| 多 Pi 叢集 | 單節點 | Google Drive / mDNS |
| 電源控制 | — | GPIO / espHome / Tasmota / DLI |
| TUI 選單 | 僅 CLI | curses 風格選單 |
| ZTP 編排 | — | 內建 |
| 安裝複雜度 | 單一 shell 腳本 | Python + 大量相依套件 |
| 程式碼量 | ~1,300 行 bash | ~15,000+ 行 Python + bash |

console-gateway 專為需要**簡單、安全、無衝突** console 伺服器且相依性最少的團隊而設計。若你需要多 Pi 叢集、電源插座控制或完整的 TUI 體驗，ConsolePi 更適合。

## 解除安裝

```bash
sudo console-gateway-uninstall
```

移除所有 bridge 服務、systemd unit、腳本、udev 規則與設定檔。Tailscale 與 UFW 規則會被保留。

## 疑難排解

**偵測不到 Serial 裝置：**
```bash
console-detect          # 檢查 USB 裝置與屬性
lsusb                   # 確認轉接器已被識別
dmesg | tail -20        # 查看核心訊息
```

**addconsole 後 symlink 未出現：**
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=tty
ls -la /dev/cgw-*
```

**Bridge 無法啟動：**
```bash
systemctl status console-lock-bridge@cgw-SW-CORE-01
journalctl -u console-lock-bridge@cgw-SW-CORE-01 -f
```

**裝置名稱漂移（ttyUSB0 變成 ttyUSB1）：**
```bash
# 這正是持久化命名存在的原因。遷移方式：
sudo consolectl addconsole    # 重新加入並建立 udev 規則
# cgw- symlink 永遠指向正確的裝置
```

**多埠轉接器：所有埠拿到相同 symlink 或 symlink 未出現：**
```bash
# 確認你的 udev 規則使用 ENV{}（而非 ATTRS{}）且包含 ID_USB_INTERFACE_NUM：
cat /etc/udev/rules.d/90-console-gateway.rules
# 正確的規則應該像這樣：
#   SUBSYSTEM=="tty", ENV{ID_USB_VENDOR_ID}=="0403", ENV{ID_USB_MODEL_ID}=="6011", \
#     ENV{ID_USB_SERIAL_SHORT}=="FT6LBZ6", ENV{ID_USB_INTERFACE_NUM}=="00", ...
# 若規則使用 ATTRS{}，請以 v2.9 重新執行 addconsole 以重新產生規則。
```

**Serial 裝置權限被拒：**
```bash
groups support
sudo usermod -aG dialout support
```

## 授權條款

MIT

## 貢獻

歡迎提交 Issue 與 Pull Request。重大變更請先開 Issue 討論。
