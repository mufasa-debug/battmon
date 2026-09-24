#!/bin/bash
# Shared Battmon configuration, battery, audio, and logging helpers.
# Compatible with the system Bash 3.2 shipped by macOS.

BATTMON_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATTMON_RUNTIME_DIR="${BATTMON_RUNTIME_DIR:-$HOME/.battmon}"
BATTMON_CONFIG_FILE="${BATTMON_CONFIG_FILE:-$BATTMON_RUNTIME_DIR/battery_config.sh}"
BATTMON_TEMPLATE_CONFIG="${BATTMON_TEMPLATE_CONFIG:-$BATTMON_COMMON_DIR/battery_config.sh}"
BATTMON_STATE_FILE="${BATTMON_STATE_FILE:-$BATTMON_RUNTIME_DIR/state}"
BATTMON_CONFIG_LOCK="${BATTMON_CONFIG_LOCK:-$BATTMON_RUNTIME_DIR/config.lock}"
BATTMON_MONITOR_LOCK="${BATTMON_MONITOR_LOCK:-$BATTMON_RUNTIME_DIR/monitor.lock}"
BATTMON_LOG_DIR="${BATTMON_LOG_DIR:-$HOME/Library/Logs/Battmon}"
BATTMON_LOG_FILE="${BATTMON_LOG_FILE:-$BATTMON_LOG_DIR/battmon.log}"
BATTMON_PLIST="${BATTMON_PLIST:-$HOME/Library/LaunchAgents/com.battery.batmon.plist}"
BATTMON_LABEL="com.battery.batmon"

CONFIG_LOADED_SIGNATURE=""
CONFIG_LOADED_PATH=""
CONFIG_WARNING=""

set_builtin_defaults() {
    REPEAT_COUNT=10
    REPEAT_DELAY_MS=100
    CHECK_INTERVAL_MS=200
    STARTUP_GRACE_SECONDS=300
    ALERT_VOLUME=60
    RESTORE_VOLUME=true
    PAUSE_MEDIA=true
    ALERTS=(
        "100:HIGH:10:100:Battery is fully charged"
        "80:HIGH:10:100:The battery is optimally charged"
        "15:LOW:15:100:Charge up your battery"
        "5:LOW:20:100:Battery is critically low"
        "1:LOW:20:100:Battery is critically low"
    )
    ALERT_TIMES=()
}

is_valid_alert_time_range() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    [ "${1%-*}" != "${1#*-}" ]
}

alert_time_is_quiet_now() {
    local range start end now now_minutes start_minutes end_minutes
    now=$(date '+%H:%M') || return 1
    [[ "$now" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    now_minutes=$((10#${now%:*} * 60 + 10#${now#*:}))
    for range in "${ALERT_TIMES[@]}"; do
        start="${range%-*}"
        end="${range#*-}"
        start_minutes=$((10#${start%:*} * 60 + 10#${start#*:}))
        end_minutes=$((10#${end%:*} * 60 + 10#${end#*:}))
        if [ "$start_minutes" -lt "$end_minutes" ]; then
            [ "$now_minutes" -ge "$start_minutes" ] && [ "$now_minutes" -lt "$end_minutes" ] && return 0
        elif [ "$now_minutes" -ge "$start_minutes" ] || [ "$now_minutes" -lt "$end_minutes" ]; then
            return 0
        fi
    done
    return 1
}

is_retired_builtin_alert() {
    case "$PARSED_LVL:$PARSED_TYP:$PARSED_MSG" in
        "39:LOW:Battery is at 39 percent"|\
        "13:LOW:Battery is at 13 percent"|\
        "10:LOW:Charge up your battery"|\
        "10:LOW:Battery is at 10 percent. Charge up your battery"|\
        "6:LOW:Battery is at 6 percent") return 0 ;;
        *) return 1 ;;
    esac
}

is_integer_in_range() {
    local value="$1"
    local minimum="$2"
    local maximum="$3"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

is_valid_alert_repeat() {
    [ "$1" = "0" ] || is_integer_in_range "$1" 1 100
}

is_automatic_low_level() {
    is_integer_in_range "$1" 1 100 && [ "$1" -lt 30 ]
}

config_signature() {
    local path="$1"
    [ -f "$path" ] || return 1
    cksum < "$path" | awk '{print $1 ":" $2}'
}

parse_alert_entry() {
    local alert="$1"
    local p1 p2 p3 p4 p5
    IFS=":" read -r p1 p2 p3 p4 p5 <<< "$alert"

    PARSED_LVL="$p1"
    PARSED_TYP="$p2"
    if [ -n "$p5" ]; then
        PARSED_REP="${p3:-$REPEAT_COUNT}"
        PARSED_DEL="${p4:-$REPEAT_DELAY_MS}"
        PARSED_MSG="$p5"
    else
        PARSED_REP="$REPEAT_COUNT"
        PARSED_DEL="$REPEAT_DELAY_MS"
        PARSED_MSG="$p3"
    fi
}

normalize_config() {
    local warnings=""
    local original_alerts=("${ALERTS[@]}")
    local original_alert_times=()
    local normalized=()
    local keys=()
    local alert alert_time key existing_index idx existing message new_message

    if [ "${#ALERT_TIMES[@]}" -gt 0 ]; then
        original_alert_times=("${ALERT_TIMES[@]}")
    fi

    if ! is_integer_in_range "${REPEAT_COUNT:-}" 1 100; then
        warnings="${warnings}invalid REPEAT_COUNT; "
        REPEAT_COUNT=10
    fi
    if ! is_integer_in_range "${REPEAT_DELAY_MS:-}" 50 60000; then
        warnings="${warnings}invalid REPEAT_DELAY_MS; "
        REPEAT_DELAY_MS=100
    fi
    if ! is_integer_in_range "${CHECK_INTERVAL_MS:-}" 50 5000; then
        warnings="${warnings}invalid CHECK_INTERVAL_MS; "
        CHECK_INTERVAL_MS=200
    fi
    if ! is_integer_in_range "${STARTUP_GRACE_SECONDS:-}" 0 3600; then
        warnings="${warnings}invalid STARTUP_GRACE_SECONDS; "
        STARTUP_GRACE_SECONDS=300
    fi
    if ! is_integer_in_range "${ALERT_VOLUME:-}" 1 100; then
        warnings="${warnings}invalid ALERT_VOLUME; "
        ALERT_VOLUME=60
    fi
    case "${RESTORE_VOLUME:-true}" in
        true|false) ;;
        *) RESTORE_VOLUME=true; warnings="${warnings}invalid RESTORE_VOLUME; " ;;
    esac
    case "${PAUSE_MEDIA:-true}" in
        true|false) ;;
        *) PAUSE_MEDIA=true; warnings="${warnings}invalid PAUSE_MEDIA; " ;;
    esac

    ALERT_TIMES=()
    for alert_time in "${original_alert_times[@]}"; do
        if is_valid_alert_time_range "$alert_time"; then
            ALERT_TIMES+=("$alert_time")
        else
            warnings="${warnings}skipped invalid alert time range; "
        fi
    done

    for alert in "${original_alerts[@]}"; do
        parse_alert_entry "$alert"
        if is_retired_builtin_alert; then
            warnings="${warnings}removed retired built-in ${PARSED_LVL}% alert; "
            continue
        fi
        if ! is_integer_in_range "$PARSED_LVL" 1 100; then
            warnings="${warnings}skipped invalid alert level; "
            continue
        fi
        if [ "$PARSED_TYP" != "LOW" ] && [ "$PARSED_TYP" != "HIGH" ]; then
            warnings="${warnings}skipped invalid alert type; "
            continue
        fi
        if is_automatic_low_level "$PARSED_LVL" && [ "$PARSED_TYP" != "LOW" ]; then
            PARSED_TYP="LOW"
            warnings="${warnings}changed below-30% alert to LOW; "
        fi
        if ! is_valid_alert_repeat "$PARSED_REP"; then
            warnings="${warnings}skipped invalid alert repeat; "
            continue
        fi
        if ! is_integer_in_range "$PARSED_DEL" 50 60000; then
            warnings="${warnings}skipped invalid alert delay; "
            continue
        fi
        [ -n "$PARSED_MSG" ] || {
            warnings="${warnings}skipped empty alert message; "
            continue
        }

        key="${PARSED_LVL}:${PARSED_TYP}"
        new_message="$PARSED_MSG"
        existing_index=""
        for idx in "${!keys[@]}"; do
            if [ "${keys[$idx]}" = "$key" ]; then
                existing_index="$idx"
                break
            fi
        done

        if [ -n "$existing_index" ]; then
            existing="${normalized[$existing_index]}"
            parse_alert_entry "$existing"
            message="$PARSED_MSG"
            if [[ ". $message. " != *". ${new_message}. "* ]]; then
                message="${message}. ${new_message}"
            fi
            # Preserve the first rule's timing and combine duplicate messages.
            normalized[$existing_index]="${PARSED_LVL}:${PARSED_TYP}:${PARSED_REP}:${PARSED_DEL}:${message}"
            warnings="${warnings}merged duplicate ${key} rule; "
        else
            keys+=("$key")
            normalized+=("${PARSED_LVL}:${PARSED_TYP}:${PARSED_REP}:${PARSED_DEL}:${PARSED_MSG}")
        fi
    done

    if [ "${#normalized[@]}" -eq 0 ]; then
        set_builtin_defaults
        warnings="${warnings}no valid alerts; restored defaults; "
    else
        ALERTS=("${normalized[@]}")
    fi
    CONFIG_WARNING="$warnings"
}

sort_alerts() {
    local sorted=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && sorted+=("$line")
    done < <(printf '%s\n' "${ALERTS[@]}" | sort -t: -k1,1nr -k2,2)
    ALERTS=("${sorted[@]}")
}

load_config() {
    local source_path=""
    set_builtin_defaults

    if [ -f "$BATTMON_CONFIG_FILE" ]; then
        source_path="$BATTMON_CONFIG_FILE"
    elif [ -f "$BATTMON_TEMPLATE_CONFIG" ]; then
        source_path="$BATTMON_TEMPLATE_CONFIG"
    fi

    if [ -n "$source_path" ]; then
        if ! /bin/bash -n "$source_path" 2>/dev/null; then
            printf 'Battmon: invalid configuration syntax in %s\n' "$source_path" >&2
            return 1
        fi
        # The active file is owner-controlled. Generated values are shell-escaped.
        source "$source_path" || return 1
        CONFIG_LOADED_PATH="$source_path"
    else
        CONFIG_LOADED_PATH=""
    fi

    normalize_config
    sort_alerts
    if [ -f "$BATTMON_CONFIG_FILE" ]; then
        CONFIG_LOADED_SIGNATURE=$(config_signature "$BATTMON_CONFIG_FILE")
    else
        CONFIG_LOADED_SIGNATURE=""
    fi
    return 0
}

ensure_runtime_dirs() {
    mkdir -p "$BATTMON_RUNTIME_DIR" "$BATTMON_LOG_DIR" || return 1
    chmod 700 "$BATTMON_RUNTIME_DIR" "$BATTMON_LOG_DIR" 2>/dev/null || true
}

list_managed_monitor_pids() {
    local pid_value command_value monitor_script="$BATTMON_RUNTIME_DIR/battery_monitor.sh"
    while read -r pid_value command_value; do
        [[ "$pid_value" =~ ^[0-9]+$ ]] || continue
        case "$command_value" in
        "/bin/bash $monitor_script"|\
        "/bin/bash $monitor_script --test-media"|\
        "/bin/bash $monitor_script --check-media-permissions"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh --test-media"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh --check-media-permissions")
                printf '%s\n' "$pid_value"
                ;;
        esac
    done < <(ps -ax -o pid=,command= 2>/dev/null)
}

is_managed_monitor_pid() {
    local pid_value="$1" command_value state_value monitor_script="$BATTMON_RUNTIME_DIR/battery_monitor.sh"
    [[ "$pid_value" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid_value" 2>/dev/null || return 1
    state_value=$(ps -p "$pid_value" -o state= 2>/dev/null || true)
    [[ "$state_value" == Z* ]] && return 1
    command_value=$(ps -p "$pid_value" -o command= 2>/dev/null || true)
    case "$command_value" in
        "/bin/bash $monitor_script"|\
        "/bin/bash $monitor_script --test-media"|\
        "/bin/bash $monitor_script --check-media-permissions"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh --test-media"|\
        "/bin/bash $BATTMON_COMMON_DIR/battery_monitor.sh --check-media-permissions") return 0 ;;
        *) return 1 ;;
    esac
}

release_config_lock() {
    rm -f "$BATTMON_CONFIG_LOCK/pid" 2>/dev/null || true
    rmdir "$BATTMON_CONFIG_LOCK" 2>/dev/null || true
}

backup_active_config() {
    [ -f "$BATTMON_CONFIG_FILE" ] || return 0
    local backup_dir="$BATTMON_RUNTIME_DIR/backups" backup_path
    mkdir -p "$backup_dir" || return 1
    chmod 700 "$backup_dir" 2>/dev/null || true
    backup_path=$(mktemp "$backup_dir/battery_config.sh.XXXXXX") || return 1
    if ! cp "$BATTMON_CONFIG_FILE" "$backup_path"; then
        rm -f "$backup_path"
        return 1
    fi
    chmod 600 "$backup_path" || {
        rm -f "$backup_path"
        return 1
    }
}

acquire_config_lock() {
    ensure_runtime_dirs || return 1
    if mkdir "$BATTMON_CONFIG_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$BATTMON_CONFIG_LOCK/pid"
        return 0
    fi

    local lock_pid=""
    lock_pid=$(sed -n '1p' "$BATTMON_CONFIG_LOCK/pid" 2>/dev/null || true)
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        printf 'Battmon: settings are being changed by process %s. Try again.\n' "$lock_pid" >&2
        return 1
    fi

    release_config_lock
    if ! mkdir "$BATTMON_CONFIG_LOCK" 2>/dev/null; then
        printf 'Battmon: could not acquire the configuration lock.\n' >&2
        return 1
    fi
    printf '%s\n' "$$" > "$BATTMON_CONFIG_LOCK/pid"
}

save_config() {
    local current_signature=""
    local temp_file=""

    normalize_config
    sort_alerts
    acquire_config_lock || return 1

    if [ -f "$BATTMON_CONFIG_FILE" ]; then
        current_signature=$(config_signature "$BATTMON_CONFIG_FILE")
        if [ -n "$CONFIG_LOADED_SIGNATURE" ] && [ "$current_signature" != "$CONFIG_LOADED_SIGNATURE" ]; then
            printf 'Battmon: settings changed in another session; your edit was not written. Reload and retry.\n' >&2
            release_config_lock
            return 1
        fi
    fi

    temp_file=$(mktemp "$BATTMON_RUNTIME_DIR/.battery_config.XXXXXX") || {
        release_config_lock
        return 1
    }

    {
        printf '#!/bin/bash\n'
        printf '# Battmon active configuration. Managed by the battmon command.\n\n'
        printf 'REPEAT_COUNT=%s\n' "$REPEAT_COUNT"
        printf 'REPEAT_DELAY_MS=%s\n' "$REPEAT_DELAY_MS"
        printf 'CHECK_INTERVAL_MS=%s\n' "$CHECK_INTERVAL_MS"
        printf 'STARTUP_GRACE_SECONDS=%s\n\n' "$STARTUP_GRACE_SECONDS"
        printf 'ALERT_VOLUME=%s\n' "$ALERT_VOLUME"
        printf 'RESTORE_VOLUME=%s\n' "$RESTORE_VOLUME"
        printf 'PAUSE_MEDIA=%s\n\n' "$PAUSE_MEDIA"
        printf 'ALERT_TIMES=(\n'
        local alert_time
        for alert_time in "${ALERT_TIMES[@]}"; do
            printf '    %q\n' "$alert_time"
        done
        printf ')\n\n'
        printf 'ALERTS=(\n'
        local alert
        for alert in "${ALERTS[@]}"; do
            printf '    %q\n' "$alert"
        done
        printf ')\n'
    } > "$temp_file" || {
        rm -f "$temp_file"
        release_config_lock
        return 1
    }

    chmod 600 "$temp_file" || {
        rm -f "$temp_file"
        release_config_lock
        return 1
    }

    # Avoid needless inode replacement and preserve the exact previous file
    # before every real change. This gives manual recovery even if a separate
    # manager or interrupted workflow writes an unwanted but valid config.
    if [ -f "$BATTMON_CONFIG_FILE" ] && cmp -s "$temp_file" "$BATTMON_CONFIG_FILE"; then
        rm -f "$temp_file"
        CONFIG_LOADED_PATH="$BATTMON_CONFIG_FILE"
        CONFIG_LOADED_SIGNATURE=$(config_signature "$BATTMON_CONFIG_FILE")
        release_config_lock
        printf 'Settings already up to date.\n'
        return 0
    fi
    if ! backup_active_config; then
        printf 'Battmon: could not back up the current settings; no changes were written.\n' >&2
        rm -f "$temp_file"
        release_config_lock
        return 1
    fi
    if ! mv -f "$temp_file" "$BATTMON_CONFIG_FILE"; then
        rm -f "$temp_file"
        release_config_lock
        return 1
    fi

    CONFIG_LOADED_PATH="$BATTMON_CONFIG_FILE"
    CONFIG_LOADED_SIGNATURE=$(config_signature "$BATTMON_CONFIG_FILE")
    release_config_lock
    printf 'Settings saved successfully.\n'
}

ensure_active_config() {
    [ -f "$BATTMON_CONFIG_FILE" ] && return 0
    ensure_runtime_dirs || return 1
    CONFIG_LOADED_SIGNATURE=""
    save_config
}

get_battery_state() {
    local raw line
    BATTERY_AVAILABLE=0
    BATTERY_PERCENT=""
    BATTERY_SOURCE="UNKNOWN"
    BATTERY_MODE="unknown"
    BATTERY_RAW=""

    raw=$(pmset -g batt 2>/dev/null) || return 1
    BATTERY_RAW="$raw"
    case "$raw" in
        *"AC Power"*) BATTERY_SOURCE="AC" ;;
        *"Battery Power"*) BATTERY_SOURCE="BATTERY" ;;
    esac

    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)% ]]; then
            BATTERY_PERCENT="${BASH_REMATCH[1]}"
            BATTERY_AVAILABLE=1
            case "$line" in
                *discharging*) BATTERY_MODE="discharging" ;;
                *"finishing charge"*|*charging*) BATTERY_MODE="charging" ;;
                *charged*) BATTERY_MODE="charged" ;;
                *) BATTERY_MODE="unknown" ;;
            esac
            break
        fi
    done <<< "$raw"

    [ "$BATTERY_AVAILABLE" -eq 1 ]
}

battery_status_label() {
    case "${BATTERY_SOURCE:-UNKNOWN}:${BATTERY_MODE:-unknown}" in
        AC:charging) printf 'Charging' ;;
        AC:charged) printf 'Plugged in, charged' ;;
        AC:discharging) printf 'Plugged in, discharging' ;;
        BATTERY:discharging) printf 'On battery' ;;
        BATTERY:*) printf 'On battery' ;;
        *) printf 'Power state unavailable' ;;
    esac
}

get_battery_percent() {
    get_battery_state || return 1
    printf '%s\n' "$BATTERY_PERCENT"
}

is_ac_power() {
    get_battery_state || return 1
    [ "$BATTERY_SOURCE" = "AC" ]
}

get_audio_settings() {
    local settings
    settings=$(osascript -e 'get {output volume, output muted} of (get volume settings)' 2>/dev/null) || return 1
    settings=${settings//,/}
    [[ "$settings" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(true|false)[[:space:]]*$ ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

set_sys_volume() {
    local value="$1"
    is_integer_in_range "$value" 0 100 || return 1
    osascript -e "set volume output volume $value" >/dev/null 2>&1
}

set_sys_muted() {
    local value="$1"
    [ "$value" = "true" ] || [ "$value" = "false" ] || return 1
    osascript -e "set volume output muted $value" >/dev/null 2>&1
}

restore_sys_audio() {
    local volume="$1"
    local muted="$2"
    is_integer_in_range "$volume" 0 100 || return 1
    if [ "$muted" = "true" ]; then
        osascript -e "set volume output volume $volume with output muted" >/dev/null 2>&1
    else
        osascript -e "set volume output volume $volume without output muted" >/dev/null 2>&1
    fi
}

format_speech_message() {
    local raw_message="$1"
    local rule_level="$2"
    local current_level="$3"
    local result="$raw_message"

    result="${result//\{percent\}/$current_level}"
    result="${result//\{level\}/$current_level}"
    result="${result//\{pct\}/$current_level}"
    if [ -n "$rule_level" ] && [ "$rule_level" != "$current_level" ]; then
        result="${result//${rule_level} percent/${current_level} percent}"
        result="${result//${rule_level} Percent/${current_level} Percent}"
        result="${result//${rule_level}%/${current_level}%}"
        result="${result//at ${rule_level}/at ${current_level}}"
        result="${result//is ${rule_level}/is ${current_level}}"
    fi
    printf '%s\n' "$result"
}

rotate_log_if_needed() {
    [ -f "$BATTMON_LOG_FILE" ] || return 0
    local size
    size=$(wc -c < "$BATTMON_LOG_FILE" 2>/dev/null || printf '0')
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1048576 ]; then
        mv -f "$BATTMON_LOG_FILE" "$BATTMON_LOG_FILE.1" 2>/dev/null || true
    fi
}

log_event() {
    ensure_runtime_dirs >/dev/null 2>&1 || return 1
    rotate_log_if_needed
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$BATTMON_LOG_FILE"
}
