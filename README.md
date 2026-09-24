# 🦇 Battmon

### Your Mac talks to you when your battery needs attention.

[![Platform](https://img.shields.io/badge/platform-macOS%2010.13+-black?style=flat&logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/built%20with-Native%20macOS%20Bash-green.svg?style=flat)](https://www.gnu.org/software/bash/)
[![Dependencies](https://img.shields.io/badge/extra%20downloads-Zero%20(None!)-blue.svg?style=flat)](#-prerequisites)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat)](LICENSE)

**Battmon** gives your Mac a clear voice. It speaks out loud when your battery is getting low or when it finishes charging. 

No more missing silent pop-up banners. No more sudden laptop shutdowns while you are working. And whenever it speaks, **it stops talking the exact second you plug in your charger or press your keyboard's Mute button.**

---

## 📺 What It Looks Like

Battmon includes a clean, easy-to-read menu that opens right in your Mac's Terminal:

```text
─── BATTMON 🦇 Battery Voice Monitor ─────────────────────────────────────
 Battery: 42% (On Battery)           | Current system volume: 75%
 Volume target: 60%                  | Silencing: Charger or MUTE/VOL-DOWN
──────────────────────────────────────────────────────────────────────────
 Configured Alerts:
  • 100% [HIGH] 20x  100ms "Battery is fully charged"
  •  80% [HIGH] 20x  100ms "The battery is optimally charged"
  •  15% [LOW ] 20x  100ms "Battery is at 15 percent"
  •   5% [LOW ] 20x  100ms "Battery is critically low"
  •   1% [LOW ] 20x  100ms "Battery is critically low"
──────────────────────────────────────────────────────────────────────────
  1) Edit an alert rule            7) Alert Times
  2) Add new battery alert         8) Audio & media settings
  3) Delete an alert rule          9) Test voice & silencing keys
  4) View all alerts & status     10) Background service controls
  5) Change repeat & pause delay  11) Reset everything to default
  6) Apply to existing rules      12) Exit Battmon
──────────────────────────────────────────────────────────────────────────
```

---

## 💡 Why Use Battmon?

* **Never miss a low battery warning**: macOS notification banners are easy to miss when watching a video, gaming, or working in full screen. Battmon actually tells you out loud before your laptop goes to sleep.
* **Protect your battery health**: Charging all the way to 100% every single time wears out lithium-ion batteries faster. Battmon can remind you at 80% so you can unplug and keep your battery healthy for years.
* **Zero battery drain & zero bloat**: Most battery apps are heavy 200MB downloads that constantly drain power. Battmon uses 100% built-in Mac tools. It uses virtually zero memory and zero battery.
* **No subscriptions or accounts**: Free forever, open source, and runs entirely offline on your Mac.

---

## ✨ Features (Explained Simply)

### 🔌 Plug In To Silence
When Battmon warns you that your battery is low, **simply plug in your charger.** The exact millisecond your charger connects, Battmon immediately stops talking. (Likewise, when it warns you that charging is finished, unplugging stops it immediately).

### 🔇 Keyboard Friendly
Don't want to plug in right now? Just press the physical **Mute (F10)** or **Volume Down (F11)** key on your keyboard. Battmon detects the keypress, stops talking mid-sentence, and leaves your sound muted.

### 🔊 Smart Volume (Never Too Quiet)
If your Mac was muted or set to a very low volume (like 10%), Battmon temporarily raises the volume so you can clearly hear the alert, and **puts your volume right back where you had it** as soon as it's done.

### 🌙 Alert Times
Choose **Alert Times** in the main menu to add, edit, or remove quiet-time ranges. Enter a start time and an end time separately, using AM or PM (for example, `2:00 AM` to `10:00 AM`). Alerts are enabled at all times until you add a range. During quiet time Battmon continues tracking battery state without speaking, so it does not replay a missed alert when quiet time ends. Overnight ranges such as `10:00 PM` to `7:00 AM` are supported.

### 🗣️ Real-Time Percentage
If your battery drops from 15% to 14% while speaking, Battmon dynamically says *"Battery is at 14 percent"*. It always tells you the real number.

### ⚡ Pick Your Own Numbers & Messages
Want an alert at 67%? Or 82%? Want it to say *"Hey, grab your charger!"* or say it in a British or French accent? You can customize any percentage, message, repeat count, and voice.

---

## 🚀 Quick Setup (30 Seconds)

### Step 1: Open Terminal
Press **`Cmd + Space`**, type **`Terminal`**, and press **Enter**.

### Step 2: Download & Install
Copy and paste this single command and press **Enter**:

```bash
git clone https://github.com/mufasa-debug/battmon.git
cd battmon
chmod +x setup.sh battmon battery_monitor.sh && ./setup.sh
```

### Step 3: Choose Quick Setup
* Press **1** and hit **Enter** for the recommended setup (alerts at 100%, 80%, 15%, 5%, and 1%).
* Or press **2** if you want to add your own custom percentages right away.

**That’s it!** Battmon is now installed and running quietly in the background. It will automatically start every time you restart your Mac. The `battmon` command and background monitor run from the checkout where setup was launched, so edits in that folder are used on their next run. Keep the folder at the same path; run `./setup.sh` again if you move it.

---

## 🎮 Everyday Usage

Once installed, you can run `battmon` from any Terminal window:

| Command | What It Does |
| :--- | :--- |
| `battmon` | Opens the interactive settings menu |
| `battmon status` | Shows your current battery %, volume, and active alerts |
| `battmon test` | Plays a test voice alert so you can test muting and charger cutoffs |
| `battmon stop` | Temporarily pauses the background monitor |
| `battmon start` | Resumes the background monitor |
| `battmon restart`| Reloads any setting changes you made |
| `battmon --help` | Shows the full help guide |

---

## 🛠️ Adding or Changing Alerts

You can change anything by typing `battmon` in Terminal:

1. Type `2` to **Add a new alert**.
2. Type the percentage you want (e.g. `25`).
3. Choose whether it triggers while **charging up** or **discharging down**.
4. Type what you want it to say (or press Enter to use the default message).
5. Choose how many times it repeats and how long to pause between repeats.

Battmon saves your changes automatically. Even if you reinstall or update Battmon in the future, your custom alerts are safely preserved.

---

## 📋 Prerequisites

* Works on **any Mac** running macOS 10.13 (High Sierra) or newer.
* **Zero extra downloads**: Uses only tools that already come with macOS (`pmset`, `say`, `osascript`, `bash`). No Homebrew, Python, or Xcode required.

---

## 🗑️ How to Uninstall

If you ever want to remove Battmon completely, just run:

```bash
cd battmon
./setup.sh --uninstall
```

This completely unloads the background service, removes global shortcuts, and cleanly removes runtime files from your Mac in one second.

---

## 🤝 For Developers

Interested in the technical internals? Battmon features:
* Asynchronous PID tracking for instant sub-second speech interruption
* Sub-100ms pause loops with floating-point `awk` arithmetic
* CoreAudio snapshot & atomic restoration via AppleScript
* LaunchAgent Aqua session binding

Read the complete [Developer & Architecture Guide](DEVELOPER_GUIDE.md) for full technical documentation and Mermaid diagrams.

---

## 📄 License

Released under the open-source [MIT License](LICENSE). Feel free to use, modify, and share!
