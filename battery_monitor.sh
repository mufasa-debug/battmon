#!/bin/bash
# Battmon background evaluation and interruptible speech engine.

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_FILE="$SCRIPT_DIR/battmon_common.sh"
if [ ! -f "$COMMON_FILE" ]; then
    printf 'Battmon: missing %s\n' "$COMMON_FILE" >&2
    exit 2
fi
source "$COMMON_FILE" || exit 2

SAY_PID=""
LOCK_HELD=0
AUDIO_MODIFIED=0
ORIG_VOL=""
ORIG_MUTED=""
ACTIVE_ALERT_VOL=""
USER_SILENCED=0

release_monitor_lock() {
    [ "$LOCK_HELD" -eq 1 ] || return 0
    rm -f "$BATTMON_MONITOR_LOCK/pid" 2>/dev/null || true
    rmdir "$BATTMON_MONITOR_LOCK" 2>/dev/null || true
    LOCK_HELD=0
}

restore_audio() {
    [ "$AUDIO_MODIFIED" -eq 1 ] || return 0
    if restore_sys_audio "$ORIG_VOL" "$ORIG_MUTED"; then
        log_event "[Audio] Restored volume=${ORIG_VOL} muted=${ORIG_MUTED}"
    else
        log_event "[Warning] Could not restore audio state"
    fi
    AUDIO_MODIFIED=0
}

stop_speech() {
    if [ -n "$SAY_PID" ] && kill -0 "$SAY_PID" 2>/dev/null; then
        kill -TERM "$SAY_PID" 2>/dev/null || true
        wait "$SAY_PID" 2>/dev/null || true
    fi
    SAY_PID=""
}

cleanup() {
    stop_speech
    if [ "$USER_SILENCED" -eq 0 ]; then
        restore_audio
    fi
    release_monitor_lock
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

acquire_monitor_lock() {
    ensure_runtime_dirs || return 1
    if mkdir "$BATTMON_MONITOR_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$BATTMON_MONITOR_LOCK/pid"
        LOCK_HELD=1
        return 0
    fi

    local lock_pid="" lock_command=""
    lock_pid=$(sed -n '1p' "$BATTMON_MONITOR_LOCK/pid" 2>/dev/null || true)
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        lock_command=$(ps -p "$lock_pid" -o command= 2>/dev/null || true)
        case "$lock_command" in
            *battery_monitor.sh*) return 2 ;;
        esac
    fi

    rm -f "$BATTMON_MONITOR_LOCK/pid" 2>/dev/null || true
    rmdir "$BATTMON_MONITOR_LOCK" 2>/dev/null || return 1
    mkdir "$BATTMON_MONITOR_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$BATTMON_MONITOR_LOCK/pid"
    LOCK_HELD=1
}

LAST_PERCENT=""
LAST_ALERT_LEVEL=""
LAST_ALERT_TYPE=""
LAST_MODE=""
LAST_SOURCE=""

load_state() {
    [ -f "$BATTMON_STATE_FILE" ] || return 0
    local first_line key value
    first_line=$(sed -n '1p' "$BATTMON_STATE_FILE" 2>/dev/null || true)
    if [[ "$first_line" == *:* ]]; then
        IFS=":" read -r LAST_PERCENT LAST_ALERT_LEVEL LAST_ALERT_TYPE <<< "$first_line"
        return 0
    fi

    while IFS="=" read -r key value; do
        case "$key" in
            LAST_PERCENT) LAST_PERCENT="$value" ;;
            LAST_ALERT_LEVEL) LAST_ALERT_LEVEL="$value" ;;
            LAST_ALERT_TYPE) LAST_ALERT_TYPE="$value" ;;
            LAST_MODE) LAST_MODE="$value" ;;
            LAST_SOURCE) LAST_SOURCE="$value" ;;
        esac
    done < "$BATTMON_STATE_FILE"

    [[ "$LAST_PERCENT" =~ ^[0-9]+$ ]] || LAST_PERCENT=""
    [[ "$LAST_ALERT_LEVEL" =~ ^[0-9]+$ ]] || LAST_ALERT_LEVEL=""
    case "$LAST_ALERT_TYPE" in LOW|HIGH|"") ;; *) LAST_ALERT_TYPE="" ;; esac
    case "$LAST_MODE" in charging|charged|discharging|unknown|"") ;; *) LAST_MODE="" ;; esac
    case "$LAST_SOURCE" in AC|BATTERY|UNKNOWN|"") ;; *) LAST_SOURCE="" ;; esac
}

write_state() {
    local percent="$1" level="$2" type="$3" mode="$4" source="$5" temp_file
    temp_file=$(mktemp "$BATTMON_RUNTIME_DIR/.state.XXXXXX") || return 1
    {
        printf 'LAST_PERCENT=%s\n' "$percent"
        printf 'LAST_ALERT_LEVEL=%s\n' "$level"
        printf 'LAST_ALERT_TYPE=%s\n' "$type"
        printf 'LAST_MODE=%s\n' "$mode"
        printf 'LAST_SOURCE=%s\n' "$source"
    } > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$BATTMON_STATE_FILE"
}

prepare_audio() {
    local settings
    settings=$(get_audio_settings) || {
        log_event "[Warning] Audio state unavailable; speaking without changing volume"
        AUDIO_MODIFIED=0
        ACTIVE_ALERT_VOL=""
        return 0
    }
    read -r ORIG_VOL ORIG_MUTED <<< "$settings"
    ACTIVE_ALERT_VOL="$ORIG_VOL"

    if [ "$ORIG_MUTED" = "true" ]; then
        if set_sys_muted false; then
            AUDIO_MODIFIED=1
        else
            log_event "[Warning] Could not unmute output"
        fi
    fi
    if [ "$ORIG_VOL" -lt "$ALERT_VOLUME" ]; then
        if set_sys_volume "$ALERT_VOLUME"; then
            ACTIVE_ALERT_VOL="$ALERT_VOLUME"
            AUDIO_MODIFIED=1
        else
            log_event "[Warning] Could not raise output volume"
        fi
    fi
}

check_user_silenced_audio() {
    [ -n "$ACTIVE_ALERT_VOL" ] || return 1
    local settings current_volume current_muted
    settings=$(get_audio_settings) || return 1
    read -r current_volume current_muted <<< "$settings"

    if [ "$current_muted" = "true" ]; then
        USER_SILENCED=1
        AUDIO_MODIFIED=0
        INTERRUPT_REASON="Mute key"
        return 0
    fi
    if [ "$current_volume" -lt "$ACTIVE_ALERT_VOL" ]; then
        USER_SILENCED=1
        AUDIO_MODIFIED=0
        INTERRUPT_REASON="Volume Down (${current_volume}%)"
        return 0
    fi
    return 1
}

power_should_cutoff() {
    local type="$1" start_source="$2"
    if [ "$type" = "LOW" ]; then
        if [ "$start_source" = "BATTERY" ] && [ "$BATTERY_SOURCE" = "AC" ]; then
            INTERRUPT_REASON="charger connected"
            return 0
        fi
        if [ "$BATTERY_MODE" = "charging" ] || [ "$BATTERY_MODE" = "charged" ]; then
            INTERRUPT_REASON="battery stopped discharging"
            return 0
        fi
    else
        if [ "$BATTERY_SOURCE" = "BATTERY" ] || [ "$BATTERY_MODE" = "discharging" ]; then
            INTERRUPT_REASON="charger disconnected or battery discharging"
            return 0
        fi
    fi
    return 1
}

poll_for_interrupt() {
    local type="$1" start_source="$2"
    if get_battery_state && power_should_cutoff "$type" "$start_source"; then
        return 0
    fi
    check_user_silenced_audio
}

speak_rule() {
    local message="$1" type="$2" repeat_count="$3" delay_ms="$4" rule_level="$5"
    local start_source="$BATTERY_SOURCE"
    local poll_ms poll_seconds repetition pause_elapsed pause_step pause_seconds spoken_message

    poll_ms="$CHECK_INTERVAL_MS"
    poll_seconds=$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms / 1000 }')

    prepare_audio
    log_event "[Alert Started] Rule ${rule_level}% ${type}; ${repeat_count} repeats; ${delay_ms}ms pause"

    repetition=1
    while [ "$repetition" -le "$repeat_count" ]; do
        if get_battery_state && power_should_cutoff "$type" "$start_source"; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON before repetition $repetition"
            return 2
        fi
        if check_user_silenced_audio; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON before repetition $repetition"
            return 2
        fi

        spoken_message=$(format_speech_message "$message" "$rule_level" "${BATTERY_PERCENT:-$rule_level}")
        log_event "[Repetition ${repetition}/${repeat_count}] Battery ${BATTERY_PERCENT:-unknown}%"
        say "$spoken_message" &
        SAY_PID=$!

        while kill -0 "$SAY_PID" 2>/dev/null; do
            if poll_for_interrupt "$type" "$start_source"; then
                log_event "[Alert Cutoff] $INTERRUPT_REASON during repetition $repetition"
                stop_speech
                return 2
            fi
            sleep "$poll_seconds"
        done
        wait "$SAY_PID" 2>/dev/null || true
        SAY_PID=""

        pause_elapsed=0
        while [ "$pause_elapsed" -lt "$delay_ms" ] && [ "$repetition" -lt "$repeat_count" ]; do
            if poll_for_interrupt "$type" "$start_source"; then
                log_event "[Alert Cutoff] $INTERRUPT_REASON after repetition $repetition"
                return 2
            fi
            pause_step="$CHECK_INTERVAL_MS"
            if [ "$pause_step" -gt "$((delay_ms - pause_elapsed))" ]; then
                pause_step=$((delay_ms - pause_elapsed))
            fi
            pause_seconds=$(awk -v ms="$pause_step" 'BEGIN { printf "%.3f", ms / 1000 }')
            sleep "$pause_seconds"
            pause_elapsed=$((pause_elapsed + pause_step))
        done
        repetition=$((repetition + 1))
    done

    log_event "[Alert Finished] Rule ${rule_level}% completed"
    return 0
}

rule_applies_to_mode() {
    local type="$1"
    if [ "$type" = "LOW" ]; then
        [ "$BATTERY_MODE" = "discharging" ]
    else
        [ "$BATTERY_MODE" = "charging" ] || [ "$BATTERY_MODE" = "charged" ]
    fi
}

select_trigger_rule() {
    SELECTED_ALERT=""
    SELECTED_LEVEL=""
    SELECTED_TYPE=""
    local alert level type exact=0 crossed=0 transitioned=0

    for alert in "${ALERTS[@]}"; do
        parse_alert_entry "$alert"
        level="$PARSED_LVL"
        type="$PARSED_TYP"
        rule_applies_to_mode "$type" || continue

        exact=0
        crossed=0
        transitioned=0
        [ "$BATTERY_PERCENT" -eq "$level" ] && exact=1

        if [ -n "$LAST_PERCENT" ]; then
            if [ "$type" = "LOW" ] && [ "$BATTERY_PERCENT" -lt "$level" ] && [ "$LAST_PERCENT" -gt "$level" ]; then
                crossed=1
            elif [ "$type" = "HIGH" ] && [ "$BATTERY_PERCENT" -gt "$level" ] && [ "$LAST_PERCENT" -lt "$level" ]; then
                crossed=1
            fi
        fi

        if [ -n "$LAST_MODE" ] && [ "$LAST_MODE" != "$BATTERY_MODE" ]; then
            if [ "$type" = "LOW" ] && [ "$BATTERY_PERCENT" -le "$level" ]; then
                transitioned=1
            elif [ "$type" = "HIGH" ] && [ "$BATTERY_PERCENT" -ge "$level" ]; then
                transitioned=1
            fi
        fi

        if [ "$exact" -eq 0 ] && [ "$crossed" -eq 0 ] && [ "$transitioned" -eq 0 ]; then
            continue
        fi
        if [ "$BATTERY_PERCENT" = "$LAST_PERCENT" ] && [ "$level" = "$LAST_ALERT_LEVEL" ] && [ "$type" = "$LAST_ALERT_TYPE" ] && [ "$BATTERY_MODE" = "$LAST_MODE" ]; then
            continue
        fi

        if [ -z "$SELECTED_ALERT" ]; then
            SELECTED_ALERT="$alert"
            SELECTED_LEVEL="$level"
            SELECTED_TYPE="$type"
            continue
        fi

        # Exact rules win. For jumps, choose the most critical crossed threshold.
        if [ "$exact" -eq 1 ]; then
            SELECTED_ALERT="$alert"
            SELECTED_LEVEL="$level"
            SELECTED_TYPE="$type"
        elif [ "$type" = "LOW" ] && [ "$level" -lt "$SELECTED_LEVEL" ]; then
            SELECTED_ALERT="$alert"
            SELECTED_LEVEL="$level"
            SELECTED_TYPE="$type"
        elif [ "$type" = "HIGH" ] && [ "$level" -gt "$SELECTED_LEVEL" ]; then
            SELECTED_ALERT="$alert"
            SELECTED_LEVEL="$level"
            SELECTED_TYPE="$type"
        fi
    done

    [ -n "$SELECTED_ALERT" ]
}

main() {
    local lock_result speech_result
    acquire_monitor_lock
    lock_result=$?
    if [ "$lock_result" -eq 2 ]; then
        exit 0
    elif [ "$lock_result" -ne 0 ]; then
        printf 'Battmon: unable to acquire monitor lock.\n' >&2
        exit 1
    fi

    if ! load_config; then
        log_event "[Error] Configuration could not be loaded"
        exit 2
    fi
    [ -n "$CONFIG_WARNING" ] && log_event "[Config] $CONFIG_WARNING"
    if [[ "$CONFIG_WARNING" == *"no valid alerts"* ]]; then
        log_event "[Error] No valid configured alerts; monitor run suppressed"
        exit 2
    fi
    load_state

    if ! get_battery_state; then
        log_event "[Warning] No supported battery was detected"
        exit 0
    fi

    if ! select_trigger_rule; then
        # Preserve the alert marker while nothing changed; clearing it here would
        # allow the same exact threshold to fire again on the following run.
        if [ "$BATTERY_PERCENT" != "$LAST_PERCENT" ] || \
            [ "$BATTERY_MODE" != "$LAST_MODE" ] || \
            [ "$BATTERY_SOURCE" != "$LAST_SOURCE" ]; then
            write_state "$BATTERY_PERCENT" "" "" "$BATTERY_MODE" "$BATTERY_SOURCE" || \
                log_event "[Warning] Could not persist state"
        fi
        exit 0
    fi

    parse_alert_entry "$SELECTED_ALERT"
    write_state "$BATTERY_PERCENT" "$PARSED_LVL" "$PARSED_TYP" "$BATTERY_MODE" "$BATTERY_SOURCE" || {
        log_event "[Error] Could not persist trigger state; alert suppressed to avoid duplicates"
        exit 1
    }
    speak_rule "$PARSED_MSG" "$PARSED_TYP" "$PARSED_REP" "$PARSED_DEL" "$PARSED_LVL"
    speech_result=$?
    # Charger, power-mode, mute, and volume-key cutoffs are expected outcomes.
    [ "$speech_result" -eq 2 ] && return 0
    return "$speech_result"
}

main "$@"
