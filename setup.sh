#!/bin/bash
# Safe Battmon installer and uninstaller for macOS.

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/.battmon"
LEGACY_DIR="$HOME/.batmon"
BIN_DIR="$HOME/.local/bin"
LINK_PATH="$BIN_DIR/battmon"
PLIST_PATH="$HOME/Library/LaunchAgents/com.battery.batmon.plist"
LOG_DIR="$HOME/Library/Logs/Battmon"
LOG_FILE="$LOG_DIR/battmon.log"
LABEL="com.battery.batmon"
START_SERVICE=1
UNINSTALL=0
PURGE=0
ASSUME_YES=0

usage() {
    cat << 'EOF'
Usage: ./setup.sh [options]

  --no-start       Install files without loading the background service
  --uninstall      Remove Battmon code and service; preserve active config
  --purge          With --uninstall, also remove config/state after backup
  --yes            Skip interactive uninstall confirmation
  -h, --help       Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-start) START_SERVICE=0 ;;
        --uninstall|uninstall|-u) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown setup option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -ne 1 ]; then
    printf '%s\n' '--purge is only valid together with --uninstall.' >&2
    usage >&2
    exit 2
fi

managed_link_target() {
    local path="$1" target=""
    [ -L "$path" ] || return 1
    target=$(readlink "$path")
    case "$target" in
        "$RUNTIME_DIR/battmon"|"$SCRIPT_DIR/battmon") return 0 ;;
    esac
    return 1
}

remove_managed_link() {
    local path="$1"
    if managed_link_target "$path"; then
        rm -f "$path"
        return 0
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        printf '  [kept] Unrelated path: %s\n' "$path"
    fi
}

list_runtime_monitor_pids() {
    local pid_value command_value monitor_script="$RUNTIME_DIR/battery_monitor.sh" source_monitor="$SCRIPT_DIR/battery_monitor.sh"
    while read -r pid_value command_value; do
        [[ "$pid_value" =~ ^[0-9]+$ ]] || continue
        case "$command_value" in
            "/bin/bash $monitor_script"|\
            "/bin/bash $monitor_script --test-media"|\
            "/bin/bash $monitor_script --check-media-permissions"|\
            "/bin/bash $source_monitor"|\
            "/bin/bash $source_monitor --test-media"|\
            "/bin/bash $source_monitor --check-media-permissions")
                printf '%s\n' "$pid_value"
                ;;
        esac
    done < <(ps -ax -o pid=,command= 2>/dev/null)
}

runtime_monitor_pid_is_alive() {
    local pid_value="$1" command_value state_value monitor_script="$RUNTIME_DIR/battery_monitor.sh" source_monitor="$SCRIPT_DIR/battery_monitor.sh"
    [[ "$pid_value" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid_value" 2>/dev/null || return 1
    state_value=$(ps -p "$pid_value" -o state= 2>/dev/null || true)
    [[ "$state_value" == Z* ]] && return 1
    command_value=$(ps -p "$pid_value" -o command= 2>/dev/null || true)
    case "$command_value" in
        "/bin/bash $monitor_script"|\
        "/bin/bash $monitor_script --test-media"|\
        "/bin/bash $monitor_script --check-media-permissions"|\
        "/bin/bash $source_monitor"|\
        "/bin/bash $source_monitor --test-media"|\
        "/bin/bash $source_monitor --check-media-permissions") return 0 ;;
        *) return 1 ;;
    esac
}

stop_service() {
    local uid_value pid_value attempts=0 remaining=0 forced_stop=0 monitor_count=0
    local monitor_pids=()
    uid_value=$(id -u)
    launchctl bootout "gui/${uid_value}/${LABEL}" >/dev/null 2>&1 || true
    while IFS= read -r pid_value; do
        if [ -n "$pid_value" ]; then
            monitor_pids+=("$pid_value")
            monitor_count=$((monitor_count + 1))
        fi
    done < <(list_runtime_monitor_pids)
    if [ "$monitor_count" -gt 0 ]; then
        for pid_value in "${monitor_pids[@]}"; do
            runtime_monitor_pid_is_alive "$pid_value" && kill -TERM "$pid_value" 2>/dev/null || true
        done
        while [ "$attempts" -lt 100 ]; do
            remaining=0
            for pid_value in "${monitor_pids[@]}"; do
                if runtime_monitor_pid_is_alive "$pid_value"; then
                    remaining=1
                    break
                fi
            done
            [ "$remaining" -eq 0 ] && break
            sleep 0.1
            attempts=$((attempts + 1))
        done
        for pid_value in "${monitor_pids[@]}"; do
            if runtime_monitor_pid_is_alive "$pid_value"; then
                kill -KILL "$pid_value" 2>/dev/null || true
                forced_stop=1
            fi
        done
    fi
    rm -f "$RUNTIME_DIR/monitor.lock/pid" 2>/dev/null || true
    rmdir "$RUNTIME_DIR/monitor.lock" 2>/dev/null || true
    [ "$forced_stop" -eq 1 ] && echo "Battmon: forced an unresponsive old monitor to stop." >&2
}

confirm_uninstall() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ ! -t 0 ]; then
        printf 'Refusing non-interactive uninstall without --yes.\n' >&2
        return 1
    fi
    local answer
    read -r -p "Uninstall Battmon? Active configuration will be preserved. (y/N): " answer || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; esac
    return 1
}

uninstall_battmon() {
    confirm_uninstall || {
        echo "Uninstall cancelled."
        return 1
    }
    stop_service
    rm -f "$PLIST_PATH"
    remove_managed_link "$LINK_PATH"
    remove_managed_link "/usr/local/bin/battmon" 2>/dev/null || true

    local alias_name
    for alias_name in Battmon batmon Batmon battery battery-monitor; do
        remove_managed_link "$BIN_DIR/$alias_name"
    done

    rm -f "$RUNTIME_DIR/battmon" "$RUNTIME_DIR/battery_monitor.sh" "$RUNTIME_DIR/battmon_common.sh"
    rm -f "$RUNTIME_DIR/monitor.lock/pid" "$RUNTIME_DIR/config.lock/pid" 2>/dev/null || true
    rmdir "$RUNTIME_DIR/monitor.lock" "$RUNTIME_DIR/config.lock" 2>/dev/null || true

    if [ "$PURGE" -eq 1 ]; then
        local backup_path="$HOME/battmon-config-backup-$(date '+%Y%m%d-%H%M%S').sh"
        if [ -f "$RUNTIME_DIR/battery_config.sh" ]; then
            cp "$RUNTIME_DIR/battery_config.sh" "$backup_path" || return 1
            chmod 600 "$backup_path" 2>/dev/null || true
            printf '  [saved] Configuration backup: %s\n' "$backup_path"
        fi
        rm -f "$RUNTIME_DIR/battery_config.sh" "$RUNTIME_DIR/state"
        rm -f "$RUNTIME_DIR"/backups/* 2>/dev/null || true
        rmdir "$RUNTIME_DIR/backups" "$RUNTIME_DIR" 2>/dev/null || true
        rm -f "$LOG_FILE" "$LOG_FILE.1"
        rmdir "$LOG_DIR" 2>/dev/null || true
    else
        echo "  [kept] Active configuration: $RUNTIME_DIR/battery_config.sh"
    fi

    echo "Battmon uninstalled safely."
}

preflight() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "Battmon requires macOS." >&2
        return 1
    fi
    local command_name missing=0
    for command_name in pmset say launchctl osascript pgrep ps ioreg sysctl awk sed sort mktemp cmp plutil; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'Missing required macOS command: %s\n' "$command_name" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1

    for command_name in battmon battery_monitor.sh battmon_common.sh battery_config.sh; do
        [ -f "$SCRIPT_DIR/$command_name" ] || {
            printf 'Missing installer file: %s\n' "$SCRIPT_DIR/$command_name" >&2
            return 1
        }
    done
    /bin/bash -n "$SCRIPT_DIR/battmon" "$SCRIPT_DIR/battery_monitor.sh" \
        "$SCRIPT_DIR/battmon_common.sh" "$SCRIPT_DIR/battery_config.sh" || return 1

    if [ -e "$LINK_PATH" ] || [ -L "$LINK_PATH" ]; then
        if ! managed_link_target "$LINK_PATH"; then
            printf 'Refusing to overwrite unrelated command: %s\n' "$LINK_PATH" >&2
            return 1
        fi
    fi
}

copy_atomic() {
    local source_path="$1" destination_path="$2" mode="$3" destination_dir temp_path
    destination_dir=$(dirname "$destination_path")
    mkdir -p "$destination_dir" || return 1
    temp_path=$(mktemp "$destination_dir/.battmon-install.XXXXXX") || return 1
    if ! cp "$source_path" "$temp_path"; then
        rm -f "$temp_path"
        return 1
    fi
    chmod "$mode" "$temp_path" || {
        rm -f "$temp_path"
        return 1
    }
    mv -f "$temp_path" "$destination_path"
}

configure_shell_path() {
    local shell_name target_files=() file export_line
    shell_name=$(basename "${SHELL:-/bin/zsh}")
    case "$shell_name" in
        zsh)
            target_files=("$HOME/.zshrc" "$HOME/.zprofile")
            ;;
        bash)
            target_files=("$HOME/.bash_profile" "$HOME/.bashrc")
            ;;
        fish)
            [ -d "$HOME/.config/fish" ] && target_files=("$HOME/.config/fish/config.fish")
            ;;
        *)
            target_files=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile")
            ;;
    esac

    export_line="export PATH=\"$BIN_DIR:\$PATH\""

    for file in "${target_files[@]}"; do
        if [ ! -f "$file" ]; then
            touch "$file" 2>/dev/null || continue
        fi
        if ! grep -q -F "$BIN_DIR" "$file" 2>/dev/null; then
            printf '\n# Battmon CLI path\n%s\n' "$export_line" >> "$file" 2>/dev/null || true
        fi
    done
}

is_bin_in_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) return 0 ;;
    esac
    if command -v battmon >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

prepare_command_link() {
    mkdir -p "$BIN_DIR" || return 1
    if [ -e "$LINK_PATH" ] || [ -L "$LINK_PATH" ]; then
        if ! managed_link_target "$LINK_PATH"; then
            printf 'Refusing to overwrite unrelated command: %s\n' "$LINK_PATH" >&2
            return 1
        fi
        rm -f "$LINK_PATH"
    fi

    local alias_name
    for alias_name in Battmon batmon Batmon battery battery-monitor; do
        remove_managed_link "$BIN_DIR/$alias_name"
    done
    ln -s "$SCRIPT_DIR/battmon" "$LINK_PATH"

    # Also link to /usr/local/bin if available and writable by user
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        if [ ! -e "/usr/local/bin/battmon" ] || managed_link_target "/usr/local/bin/battmon"; then
            ln -sf "$SCRIPT_DIR/battmon" "/usr/local/bin/battmon" 2>/dev/null || true
        fi
    fi

    configure_shell_path
}

preserve_or_seed_config() {
    mkdir -p "$RUNTIME_DIR/backups" || return 1
    chmod 700 "$RUNTIME_DIR" "$RUNTIME_DIR/backups" 2>/dev/null || true
    if [ -f "$RUNTIME_DIR/battery_config.sh" ]; then
        local backup_path
        # BSD mktemp requires the X template at the end of the pathname.
        backup_path=$(mktemp "$RUNTIME_DIR/backups/battery_config.sh.XXXXXX") || return 1
        cp "$RUNTIME_DIR/battery_config.sh" "$backup_path" || return 1
        chmod 600 "$backup_path" 2>/dev/null || true
        return 0
    fi
    if [ -f "$LEGACY_DIR/battery_config.sh" ]; then
        copy_atomic "$LEGACY_DIR/battery_config.sh" "$RUNTIME_DIR/battery_config.sh" 600
    else
        copy_atomic "$SCRIPT_DIR/battery_config.sh" "$RUNTIME_DIR/battery_config.sh" 600
    fi
}

write_plist() {
    local plist_dir temp_plist
    plist_dir=$(dirname "$PLIST_PATH")
    mkdir -p "$plist_dir" "$LOG_DIR" || return 1
    chmod 700 "$LOG_DIR" 2>/dev/null || true
    temp_plist=$(mktemp "$plist_dir/.com.battery.batmon.XXXXXX") || return 1
    cat << EOF > "$temp_plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/battery_monitor.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
    if ! plutil -lint "$temp_plist" >/dev/null; then
        rm -f "$temp_plist"
        return 1
    fi
    chmod 600 "$temp_plist" || return 1
    mv -f "$temp_plist" "$PLIST_PATH"
}

install_battmon() {
    preflight || return 1
    stop_service

    mkdir -p "$RUNTIME_DIR" "$LOG_DIR" || return 1
    chmod 700 "$RUNTIME_DIR" "$LOG_DIR" 2>/dev/null || true
    preserve_or_seed_config || return 1
    if [ ! -f "$RUNTIME_DIR/state" ] && [ -f "$HOME/.battmon_state" ]; then
        copy_atomic "$HOME/.battmon_state" "$RUNTIME_DIR/state" 600 || return 1
    fi

    copy_atomic "$SCRIPT_DIR/battmon" "$RUNTIME_DIR/battmon" 755 || return 1
    copy_atomic "$SCRIPT_DIR/battery_monitor.sh" "$RUNTIME_DIR/battery_monitor.sh" 755 || return 1
    copy_atomic "$SCRIPT_DIR/battmon_common.sh" "$RUNTIME_DIR/battmon_common.sh" 644 || return 1
    prepare_command_link || return 1

    # Validate, normalize, and safely serialize the active configuration.
    "$RUNTIME_DIR/battmon" migrate >/dev/null || return 1

    if [ "$START_SERVICE" -eq 1 ]; then
        write_plist || return 1
        local uid_value
        uid_value=$(id -u)
        if ! launchctl bootstrap "gui/${uid_value}" "$PLIST_PATH"; then
            echo "Battmon installed, but the LaunchAgent failed to load." >&2
            return 1
        fi
        if ! launchctl print "gui/${uid_value}/${LABEL}" >/dev/null 2>&1; then
            echo "Battmon installed, but the LaunchAgent could not be verified." >&2
            return 1
        fi
        echo "Battmon installed and background monitoring started."
    else
        rm -f "$PLIST_PATH"
        echo "Battmon installed; background monitoring remains stopped."
        echo "Run 'battmon start' when you want to enable it."
    fi
    echo "Command: $LINK_PATH"
    echo "Config : $RUNTIME_DIR/battery_config.sh"
    echo "Logs   : $LOG_FILE"
    if ! is_bin_in_path; then
        echo ""
        echo "💡 Next step to run 'battmon' in this terminal window:"
        echo "   export PATH=\"$BIN_DIR:\$PATH\""
        echo "   (Or open a new Terminal tab/window — your shell profile has been updated!)"
    fi
}

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_battmon
else
    install_battmon
fi
