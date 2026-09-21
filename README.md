**Battmon: macOS Battery Voice Monitor & Interactive Manager**

[![Platform](https://img.shields.io/badge/platform-macOS%2010.13+-black?style=flat&logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/language-Bash%20%7C%20AppleScript-green.svg?style=flat)](https://www.gnu.org/software/bash/)
[![Dependencies](https://img.shields.io/badge/dependencies-Zero%20(100%25%20Native)-blue.svg?style=flat)](#prerequisites)
[![UI](https://img.shields.io/badge/interface-80x24%20Terminal%20TUI-orange.svg?style=flat)](#-interactive-tui-preview)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat)](LICENSE)

> **A native macOS battery voice-alert daemon and terminal manager.**
> Speaks customizable voice alerts at any battery percentage (charging or discharging), automatically boosts system audio, and **instantly cuts off speech** when you plug in, unplug, or press your keyboard's **Mute (F10)** or **Volume Down (F11)** keys.

---

## 📸 Interactive TUI Preview

Battmon is built specifically for the default macOS terminal geometry (**80 columns × 24 rows**). Zero line wrapping, zero vertical scrolling, and no terminal jitter.

```text
─── BATTMON 🦇 Battery Voice Monitor ─────────────────────────────────────
 Battery: 42% (On Battery)           | Current system volume: 75%
 Volume target: 60%                  | Silencing: Charger or MUTE/VOL-DOWN
──────────────────────────────────────────────────────────────────────────
 Configured Alerts:
  • 100% [HIGH] 20x  100ms "Battery is fully charged"
  •  80% [HIGH] 20x  100ms "The battery is optimally charged"
  •  39% [LOW ] 20x  100ms "Battery is at 39 percent"
  •  15% [LOW ] 20x  100ms "Battery is at 15 percent"
  •  13% [LOW ] 20x   50ms "Battery is at 13 percent"
  •  10% [LOW ] 20x  100ms "Battery is at 10 percent"
    (... and 4 more alerts - view all via option 4)
──────────────────────────────────────────────────────────────────────────
  1) Edit an alert rule            7) Change volume target
  2) Add new battery alert         8) Test voice & silencing keys
  3) Delete an alert rule          9) Background service controls
  4) View all alerts & status     10) Reset everything to default
  5) Change repeat & pause delay  11) Exit Battmon
  6) Apply to existing rules
──────────────────────────────────────────────────────────────────────────
```

---

## ⚡ Why Battmon?

* macOS notification banners are silent, easy to miss when focused in full-screen apps, and don't wake you up if you step away from your desk.
* Overcharging above 80% accelerates lithium-ion battery wear; deep discharging below 10% risks sudden system shutdown and data loss.
* Most battery utilities are bloated 200MB Electron applications or paid menu-bar subscriptions.
* **Battmon is 100% native**: It uses macOS built-in tools (`pmset`, `say`, `osascript`, `launchd`), consumes **zero idle CPU**, requires **no Homebrew, Python, or Node.js**, and runs quietly as a native user LaunchAgent.

---

## ✨ Key Features

### 🔇 Multi-Way Instant Silencing
No annoying loops you cannot stop. You can silence an alert mid-syllable at any second:
1. **Plug In / Unplug Charger**:
   * For **LOW** battery alerts: plugging in your charger cuts speech off immediately.
   * For **HIGH** (charging) alerts: unplugging your charger cuts speech off immediately.
2. **Keyboard Mute Key (F10)**:
   * Press physical **MUTE** &rarr; Battmon cuts speech off instantly and keeps your Mac muted.
3. **Keyboard Volume Down Key (F11)**:
   * Press **VOLUME DOWN** &rarr; Battmon detects the audio drop, terminates the speech loop, and preserves your chosen quieter volume.

### 🔊 Smart Audio Management & Exact Restoration
* **Auto-Unmute & Volume Boost**: If your audio is muted or too quiet (e.g. 15%), Battmon temporarily raises the volume to your configured target (default 60%) so you never miss an alert.
* **Guaranteed State Restoration**: The millisecond the alert finishes or is silenced, Battmon restores your exact previous audio state:
  * If volume was 24%, it returns to 24%.
  * If your Mac was muted, it returns to muted.

### 🗣️ Dynamic Real-Time Spoken Percentage
If your battery drops while an alert is speaking (e.g. alert triggers at 15%, but discharges to 14% on repeat 4), Battmon reads the live battery sensor and speaks `"Battery is at 14 percent"`. It never repeats stale numbers.

### ⏱️ Sub-100ms High-Frequency Pauses
Configurable pause intervals between spoken repetitions down to **50 ms** (default is 100 ms). Fine-tuned via floating-point sub-second timing loops.

### 🛡️ Bidirectional Dual-Sync Persistence
Settings saved via the terminal GUI (`battmon`) write atomically to both the runtime daemon directory (`~/.battmon/`) and your local repository/Desktop folder. Re-running `./setup.sh` or uninstallation will never wipe your custom alerts.

### 🔍 Duplicate Alert Collision Protection
Adding an alert percentage that already exists triggers an instant conflict prompt displaying the existing settings and offering to edit, overwrite, choose another percentage, or cancel.

---

## 🚀 Quick Setup (Install in 30 Seconds)

### Option A: One-Line Installation (Recommended)

Clone the repository and run the setup wizard:

```bash
git clone https://github.com/mufasa-debug/battmon.git
cd battmon
chmod +x setup.sh battmon battery_monitor.sh && ./setup.sh
```

### Option B: Manual Folder Installation

1. Download or unzip the repository onto your Mac (e.g., `~/Desktop/Battmon`).
2. Open **Terminal**, type `cd ` (with a trailing space), and drag-and-drop the `Battmon` folder into the Terminal window.
3. Run:
   ```bash
   chmod +x setup.sh battmon battery_monitor.sh && ./setup.sh
   ```
4. Choose **1** for Quick Install (default alerts) or **2** for Custom Setup.

---

## 🎮 Command-Line Usage

Once installed, the `battmon` CLI is globally available from any terminal session:

```bash
# Open interactive 80x24 manager
battmon

# Check live battery status, audio level & configured rules
battmon status

# Interactive voice & key silencing test (Charger / Mute / Volume Down)
battmon test

# Trigger an immediate background check cycle
battmon run

# Background daemon service controls
battmon start      # Register & start daemon
battmon stop       # Stop background daemon
battmon restart    # Reload daemon with latest battery_config.sh

# Open battery_config.sh directly in your terminal editor
battmon edit

# View CLI manual
battmon --help
```

---

## ⚙️ Configuration & Rule Syntax

Configuration is stored in `~/.battmon/battery_config.sh` and automatically synchronized. You can modify settings using the interactive menu (`battmon`) or edit the file directly (`battmon edit`).

```bash
# Global defaults
REPEAT_COUNT=20          # Default repeat count
REPEAT_DELAY_MS=100      # Default pause between repetitions (min: 50 ms)
CHECK_INTERVAL_MS=200    # Background key-polling resolution
ALERT_VOLUME=60          # Alert volume level (0-100%)
RESTORE_VOLUME=true      # Auto-restore previous volume when alert finishes

# Configured alert rules
ALERTS=(
    "100:HIGH:20:100:Battery is fully charged"
    "80:HIGH:20:100:The battery is optimally charged"
    "39:LOW:20:100:Battery is at 39 percent"
    "15:LOW:20:100:Battery is at 15 percent"
    "13:LOW:20:50:Battery is at 13 percent"
    "10:LOW:20:100:Charge up your battery"
    "6:LOW:15:100:Battery is at 6 percent"
    "5:LOW:20:100:Battery is critically low"
    "1:LOW:20:100:Battery is critically low"
)
```

### Alert Tuple Specification
Each rule inside `ALERTS` is defined as:
```text
"<PERCENT>:<CONDITION>:<REPEATS>:<DELAY_MS>:<MESSAGE>"
```

| Field | Description | Accepted Values |
| :--- | :--- | :--- |
| `PERCENT` | Battery percentage trigger threshold | `1` - `100` |
| `CONDITION` | Power state trigger condition | `HIGH` (Charging up to %) or `LOW` (Discharging down to %) |
| `REPEATS` | How many times the voice alert speaks | `1` - `100` |
| `DELAY_MS` | Pause between spoken repetitions in milliseconds | `50` - `60000` (min: 50 ms, default: 100 ms) |
| `MESSAGE` | Text-to-speech phrase spoken by macOS | Any text string |

---

## 🏗️ Architecture & How It Works

Battmon runs as a user-level macOS **LaunchAgent** (`com.battery.batmon.plist`) inside your active graphical Aqua session.

```text
[pmset -g batt]  -->  Evaluates Battery % & AC Power
                              │
                              ▼
[battery_monitor.sh] --> Reads ~/.battmon_state (prevents duplicate triggers)
                              │
                              ▼
                     Fires Matching Alert
                              │
                              ├─► Snapshot Volume & Mute (osascript)
                              ├─► Boost Volume to Target (e.g. 60%)
                              ├─► Fork Speech: say "$msg" & (PID tracking)
                              │     │
                              │     └─► Polls every 200ms: Charger? MUTE? VOL DOWN?
                              │           └─► IF Detected: kill say_pid mid-syllable
                              │
                              └─► Guaranteed Audio Restore (EXIT/TERM/INT trap)
```

For complete architectural specifications, IPC, and sub-second polling mechanics, see the [Developer Reference Guide](DEVELOPER_GUIDE.md).

---

## 📋 Prerequisites

Battmon requires **macOS 10.13 (High Sierra)** or later. It runs completely out-of-the-box using native tools:
* `pmset` (Power management daemon)
* `say` (Native speech synthesis)
* `osascript` (CoreAudio control via AppleScript)
* `launchctl` (macOS background job manager)
* `bash` / `awk` (Standard POSIX shell utilities)

**No external packages, Python runtimes, or Homebrew dependencies required.**

---

## 🗑️ Uninstallation

To remove Battmon cleanly:

```bash
./setup.sh --uninstall
```

This will:
* Unload and delete the LaunchAgent service (`com.battery.batmon.plist`)
* Remove the global CLI commands (`~/.local/bin/battmon`)
* Clean up the runtime daemon directory (`~/.battmon/`)
* **Safely preserve** your customized alerts in your local `battery_config.sh`

---

## 🤝 Contributing

Contributions, feature suggestions, and bug reports are welcome!
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

Distributed under the **MIT License**. See `LICENSE` for more information.
