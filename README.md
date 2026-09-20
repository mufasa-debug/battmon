# 🦇 Battmon: macOS Battery Voice Monitor & Interactive Manager

**Battmon** is an all-in-one battery voice alert system and interactive management tool built natively for macOS. It monitors your MacBook's battery, speaks custom text-to-speech phrases when targets are hit, and automatically stops talking the millisecond you plug in or unplug your charger, or when you press the Mute / Volume Down key.

---

## ⚡ Quick 1-Minute Universal Installation

Installable on **any** Mac:

Open Terminal inside the `Battmon` folder and run:

```bash
chmod +x setup.sh battmon battery_monitor.sh && ./setup.sh
```

---

## 📖 Command-Line Usage

```bash
battmon            # Open interactive manager
battmon -h         # Show help manual
battmon status     # Check battery level and alert rules
battmon test       # Test voice and key cutoffs
```

---

## 🔇 Multiple Ways to Silence an Alert Immediately

1. **Connect / Disconnect Charger**:
   - For low-battery alerts: connecting your charger cuts off speech immediately.
   - For fully/optimally charged alerts: disconnecting your charger cuts off speech immediately.
2. **MacBook Keyboard Mute Button**:
   - Press the physical **Mute button (F10)** on your keyboard -> Battmon cuts off speech mid-syllable and keeps your Mac muted.
3. **MacBook Keyboard Volume Down Button**:
   - Press the physical **Volume Down button (F11)** on your keyboard -> Battmon detects the volume drop and cuts off speech immediately, keeping your volume at the lower level you selected.

---

## 🔊 Smart Volume Control & Automatic State Restoration

1. **Auto-Unmute**: If your Mac is on mute, Battmon automatically un-mutes it prior to speaking.
2. **Dynamic Volume Adjustment**: If your current volume is lower than the configured target (e.g. 60%), Battmon temporarily raises it to ensure the alert is heard clearly.
3. **Exact State Restoration**: The moment an action happens (e.g. you plug in or unplug the charger, or when the alert finishes):
   - If your volume was `32%`, it returns back to `32%`.
   - If your Mac was `muted`, it returns back to `muted`.
