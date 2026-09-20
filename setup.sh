#!/bin/bash
# ==============================================================================
# BATTMON: Universal Setup & Installation Wizard
# Works on any macOS machine. Standard 80x24 terminal friendly.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_FILE="$SCRIPT_DIR/requirements.txt"
CONFIG_FILE="$SCRIPT_DIR/battery_config.sh"
PLIST_DST="$HOME/Library/LaunchAgents/com.battery.batmon.plist"
RUNTIME_DIR="$HOME/.battmon"
BIN_DIR="$HOME/.local/bin"

if [ "$1" = "--uninstall" ] || [ "$1" = "uninstall" ] || [ "$1" = "-u" ]; then
    echo "─── BATTMON: Uninstalling ────────────────────────────────────────────────"
    launchctl bootout "gui/$(id -u)/com.battery.batmon" 2>/dev/null || launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -f "$BIN_DIR/battmon" "$BIN_DIR/Battmon" "$BIN_DIR/batmon" "$BIN_DIR/Batmon" "$BIN_DIR/battery" "$BIN_DIR/battery-monitor"
    if [ -f "$RUNTIME_DIR/battery_config.sh" ] && [ -d "$SCRIPT_DIR" ] && [ "$SCRIPT_DIR" != "$BIN_DIR" ]; then
        cp "$RUNTIME_DIR/battery_config.sh" "$SCRIPT_DIR/battery_config.sh" 2>/dev/null || true
    fi
    rm -rf "$RUNTIME_DIR" "$HOME/.batmon"
    rm -f /tmp/battmon.log /tmp/batmon.log /tmp/batmon_state /tmp/battmon_state /tmp/battmon_test_active /tmp/battmon_test_active
    echo "  [✔] Background service unloaded & removed"
    echo "  [✔] Global commands removed ($BIN_DIR)"
    echo "  [✔] Custom alerts & configuration preserved in $SCRIPT_DIR/battery_config.sh"
    echo "  [✔] Background runtime folder removed (~/.battmon/)"
    echo "──────────────────────────────────────────────────────────────────────────"
    echo "Battmon has been completely uninstalled."
    echo "Your installer folder remains ready at: $SCRIPT_DIR"
    exit 0
fi

clear 2>/dev/null || echo ""
echo "─── BATTMON 🦇 macOS Battery Monitor Setup ───────────────────────────────"
echo "Monitors battery every 60s, speaks alerts at custom %, with smart volume"
echo "and instant cutoff via charger or keyboard MUTE (F10) / VOL DOWN (F11)."
echo "──────────────────────────────────────────────────────────────────────────"

# STEP 1: Smart Dependency Check (Checks installed vs missing, installs ONLY missing)
echo "[1/3] Checking requirements..."
MISSING_REQS=()
INSTALLED_REQS=()

if [ -f "$REQ_FILE" ]; then
    while IFS= read -r req || [ -n "$req" ]; do
        req=$(echo "$req" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$req" ] && continue

        if command -v "$req" >/dev/null 2>&1; then
            bin_path=$(command -v "$req")
            echo "  [✔] Installed: $req ($bin_path) -> Skipped"
            INSTALLED_REQS+=("$req")
        else
            echo "  [✗] NOT installed: $req -> Installing"
            MISSING_REQS+=("$req")
        fi
    done < "$REQ_FILE"
fi

if [ ${#MISSING_REQS[@]} -eq 0 ]; then
    echo "  All requirements already installed. No installations needed."
else
    for missing in "${MISSING_REQS[@]}"; do
        if command -v brew >/dev/null 2>&1; then
            brew install "$missing" || true
        else
            echo "  Please install Command Line Tools: xcode-select --install"
            exit 1
        fi
    done
fi
echo "──────────────────────────────────────────────────────────────────────────"

# STEP 2: Configuration Options
echo "[2/3] Setup options:"
echo "  1) Quick Install: Use recommended alerts & 60% volume target"
echo "  2) Custom Setup : Add custom percentages (e.g. 67%, 82%) now"
while true; do
    read -r -p "Choose either 1 or 2 (Pressing Enter will default to 1, or 'c' to cancel): " setup_choice
    setup_choice=$(echo "$setup_choice" | tr -d '[:space:]')
    if [ "$setup_choice" = "c" ] || [ "$setup_choice" = "C" ]; then
        echo "Setup cancelled."
        exit 0
    fi
    if [ -z "$setup_choice" ] || [ "$setup_choice" = "1" ]; then
        setup_choice=1
        break
    elif [ "$setup_choice" = "2" ]; then
        setup_choice=2
        break
    else
        echo "Please enter 1 or 2 (or 'c' to cancel)."
    fi
done

if [ "$setup_choice" = "2" ]; then
    "$SCRIPT_DIR/battmon"
fi
echo "──────────────────────────────────────────────────────────────────────────"

# STEP 3: Universal Plist & Daemon Installation
echo "[3/3] Installing background service & terminal commands..."
mkdir -p "$RUNTIME_DIR" "$HOME/.batmon" "$BIN_DIR" "$HOME/Library/LaunchAgents"

chmod +x "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/battmon" "$SCRIPT_DIR/battery_monitor.sh" "$SCRIPT_DIR/battery_config.sh" 2>/dev/null || true

cp "$SCRIPT_DIR/battmon" "$RUNTIME_DIR/battmon"
chmod +x "$RUNTIME_DIR/battmon"

cp "$SCRIPT_DIR/battery_monitor.sh" "$RUNTIME_DIR/battery_monitor.sh"
chmod +x "$RUNTIME_DIR/battery_monitor.sh"
cp "$SCRIPT_DIR/battery_monitor.sh" "$HOME/.batmon/battery_monitor.sh"
chmod +x "$HOME/.batmon/battery_monitor.sh"

# Preserve any customized alerts so re-running setup never overwrites user alerts
if [ -f "$RUNTIME_DIR/battery_config.sh" ]; then
    if [ "$RUNTIME_DIR/battery_config.sh" -nt "$SCRIPT_DIR/battery_config.sh" ]; then
        cp "$RUNTIME_DIR/battery_config.sh" "$SCRIPT_DIR/battery_config.sh" 2>/dev/null || true
    else
        cp "$SCRIPT_DIR/battery_config.sh" "$RUNTIME_DIR/battery_config.sh" 2>/dev/null || true
    fi
else
    cp "$SCRIPT_DIR/battery_config.sh" "$RUNTIME_DIR/battery_config.sh"
fi
chmod +x "$RUNTIME_DIR/battery_config.sh" 2>/dev/null || true
cp "$RUNTIME_DIR/battery_config.sh" "$HOME/.batmon/battery_config.sh" 2>/dev/null || true
chmod +x "$HOME/.batmon/battery_config.sh" 2>/dev/null || true

# Dynamically generate LaunchAgent for this user's machine (universal for any Mac)
cat << EOF > "$PLIST_DST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.battery.batmon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.battmon/battery_monitor.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>StandardOutPath</key>
    <string>/tmp/battmon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/battmon.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST" 2>/dev/null || true

for name in battmon Battmon batmon Batmon battery battery-monitor; do
    ln -sf "$RUNTIME_DIR/battmon" "$BIN_DIR/$name"
done

for shrc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile"; do
    if [ -f "$shrc" ]; then
        if ! grep -q '\.local/bin' "$shrc"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shrc"
        fi
    fi
done

echo "  [✔] Daemon installed (~/.battmon/)"
echo "  [✔] Auto-start enabled on boot: $PLIST_DST"
echo "  [✔] Global commands: 'battmon', 'Battmon', 'batmon'"
echo "──────────────────────────────────────────────────────────────────────────"
echo "🎉 Installation Complete! Battmon runs in the background every 60s."
echo "Type 'battmon' in any terminal to open the manager."
echo "Type 'battmon --help' to view all commands."
echo "──────────────────────────────────────────────────────────────────────────"
