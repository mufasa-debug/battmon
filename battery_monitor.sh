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
ALERT_WATCH_PID=""
ALERT_WATCH_DIR=""
LOCK_HELD=0
AUDIO_MODIFIED=0
ORIG_VOL=""
ORIG_MUTED=""
ACTIVE_ALERT_VOL=""
USER_SILENCED=0
MEDIA_PAUSED_APPS=()
MEDIA_WAS_PLAYING=0
MEDIA_NATIVE_WARNINGS=()
MEDIA_BROWSER_WARNINGS=()
MONITOR_LOCK_OWNER_PID=""
BROWSER_PAUSE_JS='(()=>{let n=0;for(const m of document.querySelectorAll("audio,video")){if(!m.paused&&!m.ended){m.setAttribute("data-battmon-paused-by-daemon","1");m.pause();n++;}}return n;})()'
BROWSER_RESUME_JS='(()=>{let n=0;for(const m of document.querySelectorAll("audio,video")){if(m.getAttribute("data-battmon-paused-by-daemon")==="1"){m.removeAttribute("data-battmon-paused-by-daemon");m.play().catch(()=>{});n++;}}return n;})()'
BROWSER_PERMISSION_JS='(()=>1)()'

release_monitor_lock() {
    [ "$LOCK_HELD" -eq 1 ] || return 0
    rm -f "$BATTMON_MONITOR_LOCK/pid" 2>/dev/null || true
    rmdir "$BATTMON_MONITOR_LOCK" 2>/dev/null || true
    LOCK_HELD=0
}

restore_audio() {
    if [ "$AUDIO_MODIFIED" -ne 1 ] && [ "$MEDIA_WAS_PLAYING" -ne 1 ]; then
        return 0
    fi
    [ -n "$ORIG_VOL" ] && [ -n "$ORIG_MUTED" ] || return 0
    if restore_sys_audio "$ORIG_VOL" "$ORIG_MUTED"; then
        log_event "[Audio] Restored volume=${ORIG_VOL} muted=${ORIG_MUTED}"
    else
        log_event "[Warning] Could not restore audio state"
    fi
    AUDIO_MODIFIED=0
}

media_app_running() {
    pgrep -x "$1" >/dev/null 2>&1
}

pause_scriptable_player() {
    local process_name="$1" app_name="$2" state
    media_app_running "$process_name" || return 1
    state=$(osascript \
        -e 'with timeout of 2 seconds' \
        -e "tell application \"$app_name\"" \
        -e 'if player state is playing then return "playing"' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'return "not-playing"' 2>/dev/null) || {
            MEDIA_NATIVE_WARNINGS+=("$app_name")
            return 1
        }
    [ "$state" = "playing" ] || return 1
    osascript -e 'with timeout of 2 seconds' \
        -e "tell application \"$app_name\" to pause" \
        -e 'end timeout' >/dev/null 2>&1 || {
            MEDIA_NATIVE_WARNINGS+=("$app_name")
            return 1
        }
    MEDIA_PAUSED_APPS+=("$app_name")
    MEDIA_WAS_PLAYING=1
    log_event "[Media] Paused $app_name"
}

pause_chromium_browser() {
    local process_name="$1" app_name="$2" result paused_count attempted_count error_count
    media_app_running "$process_name" || return 1
    result=$(osascript \
        -e 'on run argv' \
        -e 'set mediaScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e "tell application \"$app_name\"" \
        -e 'set pausedCount to 0' \
        -e 'set attemptedCount to 0' \
        -e 'set errorCount to 0' \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then' \
        -e 'set attemptedCount to attemptedCount + 1' \
        -e 'set pauseResult to execute browserTab javascript mediaScript' \
        -e 'set pausedCount to pausedCount + (pauseResult as integer)' \
        -e 'end if' \
        -e 'on error' \
        -e 'set errorCount to errorCount + 1' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'return (pausedCount as text) & ":" & (attemptedCount as text) & ":" & (errorCount as text)' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_PAUSE_JS" 2>/dev/null) || {
            MEDIA_BROWSER_WARNINGS+=("$app_name")
            return 1
        }
    IFS=: read -r paused_count attempted_count error_count <<< "$result"
    [[ "$paused_count" =~ ^[0-9]+$ ]] || {
        MEDIA_BROWSER_WARNINGS+=("$app_name")
        return 1
    }
    if [[ "$attempted_count" =~ ^[0-9]+$ ]] && [[ "$error_count" =~ ^[0-9]+$ ]] && \
        [ "$attempted_count" -gt 0 ] && [ "$error_count" -ge "$attempted_count" ]; then
        MEDIA_BROWSER_WARNINGS+=("$app_name")
    fi
    [ "$paused_count" -gt 0 ] || return 1
    MEDIA_PAUSED_APPS+=("$app_name")
    MEDIA_WAS_PLAYING=1
    log_event "[Media] Paused $paused_count browser media element(s) in $app_name"
}

pause_safari_browser() {
    local result paused_count attempted_count error_count
    media_app_running "Safari" || return 1
    result=$(osascript \
        -e 'on run argv' \
        -e 'set mediaScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e 'tell application "Safari"' \
        -e 'set pausedCount to 0' \
        -e 'set attemptedCount to 0' \
        -e 'set errorCount to 0' \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then' \
        -e 'set attemptedCount to attemptedCount + 1' \
        -e 'set pauseResult to do JavaScript mediaScript in browserTab' \
        -e 'set pausedCount to pausedCount + (pauseResult as integer)' \
        -e 'end if' \
        -e 'on error' \
        -e 'set errorCount to errorCount + 1' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'return (pausedCount as text) & ":" & (attemptedCount as text) & ":" & (errorCount as text)' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_PAUSE_JS" 2>/dev/null) || {
            MEDIA_BROWSER_WARNINGS+=("Safari")
            return 1
        }
    IFS=: read -r paused_count attempted_count error_count <<< "$result"
    [[ "$paused_count" =~ ^[0-9]+$ ]] || {
        MEDIA_BROWSER_WARNINGS+=("Safari")
        return 1
    }
    if [[ "$attempted_count" =~ ^[0-9]+$ ]] && [[ "$error_count" =~ ^[0-9]+$ ]] && \
        [ "$attempted_count" -gt 0 ] && [ "$error_count" -ge "$attempted_count" ]; then
        MEDIA_BROWSER_WARNINGS+=("Safari")
    fi
    [ "$paused_count" -gt 0 ] || return 1
    MEDIA_PAUSED_APPS+=("Safari")
    MEDIA_WAS_PLAYING=1
    log_event "[Media] Paused $paused_count browser media element(s) in Safari"
}

resume_chromium_browser() {
    local app_name="$1"
    osascript \
        -e 'on run argv' \
        -e 'set mediaScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e "tell application \"$app_name\"" \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then execute browserTab javascript mediaScript' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_RESUME_JS" >/dev/null 2>&1
}

resume_safari_browser() {
    osascript \
        -e 'on run argv' \
        -e 'set mediaScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e 'tell application "Safari"' \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then do JavaScript mediaScript in browserTab' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_RESUME_JS" >/dev/null 2>&1
}

pause_quicktime_player() {
    local state
    media_app_running "QuickTime Player" || return 1
    state=$(osascript \
        -e 'with timeout of 2 seconds' \
        -e 'tell application "QuickTime Player"' \
        -e 'if (count documents) > 0 then' \
        -e 'if playing of front document then return "playing"' \
        -e 'end if' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'return "not-playing"' 2>/dev/null) || {
            MEDIA_NATIVE_WARNINGS+=("QuickTime Player")
            return 1
        }
    [ "$state" = "playing" ] || return 1
    osascript -e 'with timeout of 2 seconds' \
        -e 'tell application "QuickTime Player" to pause front document' \
        -e 'end timeout' >/dev/null 2>&1 || {
            MEDIA_NATIVE_WARNINGS+=("QuickTime Player")
            return 1
        }
    MEDIA_PAUSED_APPS+=("QuickTime Player")
    MEDIA_WAS_PLAYING=1
    log_event "[Media] Paused QuickTime Player"
}

pause_active_media() {
    [ "${PAUSE_MEDIA:-true}" = "true" ] || return 0
    MEDIA_PAUSED_APPS=()
    MEDIA_WAS_PLAYING=0
    MEDIA_NATIVE_WARNINGS=()
    MEDIA_BROWSER_WARNINGS=()
    pause_scriptable_player "Music" "Music" || true
    pause_scriptable_player "Spotify" "Spotify" || true
    pause_quicktime_player || true
    pause_chromium_browser "Google Chrome" "Google Chrome" || true
    pause_chromium_browser "Brave Browser" "Brave Browser" || true
    pause_chromium_browser "Microsoft Edge" "Microsoft Edge" || true
    pause_chromium_browser "Vivaldi" "Vivaldi" || true
    pause_chromium_browser "Chromium" "Chromium" || true
    pause_safari_browser || true
}

resume_paused_media() {
    local app
    [ "${#MEDIA_PAUSED_APPS[@]}" -gt 0 ] || return 0
    for app in "${MEDIA_PAUSED_APPS[@]}"; do
        if ! media_app_running "$app"; then
            log_event "[Media] Did not resume $app because it is no longer running"
            continue
        fi
        if [ "$app" = "QuickTime Player" ]; then
            if osascript -e 'with timeout of 2 seconds' \
                -e 'tell application "QuickTime Player" to play front document' \
                -e 'end timeout' >/dev/null 2>&1; then
                log_event "[Media] Resumed QuickTime Player"
            else
                log_event "[Warning] Could not resume QuickTime Player"
            fi
        elif [ "$app" = "Safari" ]; then
            if resume_safari_browser; then
                log_event "[Media] Resumed browser media in Safari"
            else
                log_event "[Warning] Could not resume browser media in Safari"
            fi
        elif [ "$app" = "Google Chrome" ] || [ "$app" = "Brave Browser" ] || \
            [ "$app" = "Microsoft Edge" ] || [ "$app" = "Vivaldi" ] || \
            [ "$app" = "Chromium" ]; then
            if resume_chromium_browser "$app"; then
                log_event "[Media] Resumed browser media in $app"
            else
                log_event "[Warning] Could not resume browser media in $app"
            fi
        elif osascript -e 'with timeout of 2 seconds' \
            -e "tell application \"$app\" to play" \
            -e 'end timeout' >/dev/null 2>&1; then
            log_event "[Media] Resumed $app"
        else
            log_event "[Warning] Could not resume $app"
        fi
    done
    MEDIA_PAUSED_APPS=()
    MEDIA_WAS_PLAYING=0
}

stop_speech() {
    if [ -n "$SAY_PID" ] && kill -0 "$SAY_PID" 2>/dev/null; then
        kill -TERM "$SAY_PID" 2>/dev/null || true
        wait "$SAY_PID" 2>/dev/null || true
    fi
    SAY_PID=""
}

stop_alert_watch() {
    if [ -n "$ALERT_WATCH_PID" ]; then
        kill -TERM "$ALERT_WATCH_PID" 2>/dev/null || true
        wait "$ALERT_WATCH_PID" 2>/dev/null || true
        ALERT_WATCH_PID=""
    fi
    if [ -n "$ALERT_WATCH_DIR" ]; then
        rm -f "$ALERT_WATCH_DIR/cutoff" "$ALERT_WATCH_DIR/cutoff.tmp" 2>/dev/null || true
        rmdir "$ALERT_WATCH_DIR" 2>/dev/null || true
        ALERT_WATCH_DIR=""
    fi
}

cleanup() {
    stop_speech
    stop_alert_watch
    if [ "$USER_SILENCED" -eq 0 ] || [ "$MEDIA_WAS_PLAYING" -eq 1 ]; then
        restore_audio
    fi
    resume_paused_media
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
            *battery_monitor.sh*)
                MONITOR_LOCK_OWNER_PID="$lock_pid"
                return 2
                ;;
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
LAST_SESSION_BLOCKED=0

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
            LAST_SESSION_BLOCKED) LAST_SESSION_BLOCKED="$value" ;;
        esac
    done < "$BATTMON_STATE_FILE"

    [[ "$LAST_PERCENT" =~ ^[0-9]+$ ]] || LAST_PERCENT=""
    [[ "$LAST_ALERT_LEVEL" =~ ^[0-9]+$ ]] || LAST_ALERT_LEVEL=""
    case "$LAST_ALERT_TYPE" in LOW|HIGH|"") ;; *) LAST_ALERT_TYPE="" ;; esac
    case "$LAST_MODE" in charging|charged|discharging|unknown|"") ;; *) LAST_MODE="" ;; esac
    case "$LAST_SOURCE" in AC|BATTERY|UNKNOWN|"") ;; *) LAST_SOURCE="" ;; esac
    case "$LAST_SESSION_BLOCKED" in 0|1) ;; *) LAST_SESSION_BLOCKED=0 ;; esac
}

write_state() {
    local percent="$1" level="$2" type="$3" mode="$4" source="$5"
    local session_blocked="${6:-0}" temp_file
    temp_file=$(mktemp "$BATTMON_RUNTIME_DIR/.state.XXXXXX") || return 1
    {
        printf 'LAST_PERCENT=%s\n' "$percent"
        printf 'LAST_ALERT_LEVEL=%s\n' "$level"
        printf 'LAST_ALERT_TYPE=%s\n' "$type"
        printf 'LAST_MODE=%s\n' "$mode"
        printf 'LAST_SOURCE=%s\n' "$source"
        printf 'LAST_SESSION_BLOCKED=%s\n' "$session_blocked"
    } > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$BATTMON_STATE_FILE"
}

session_lock_state() {
    # Reduce ioreg's potentially large output inside awk. Copying and stripping
    # the full response in Bash can become quadratic and leave the monitor lock
    # held indefinitely on some macOS versions.
    ioreg -l -w 0 -d 1 -c IOResources 2>/dev/null | LC_ALL=C awk '
        /"CGSSessionScreenIsLocked"[[:space:]]*=[[:space:]]*(Yes|true|1)/ {
            locked = 1
            exit
        }
        /"IOConsoleUsers"/ && /"kCGSessionLoginDoneKey"[[:space:]]*=[[:space:]]*Yes/ {
            unlocked = 1
        }
        END {
            if (locked) print "locked"
            else if (unlocked) print "unlocked"
            else print "unknown"
        }
    '
}

system_uptime_seconds() {
    local boot_info boot_epoch now
    boot_info=$(sysctl -n kern.boottime 2>/dev/null) || return 1
    if [[ "$boot_info" =~ sec[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
        boot_epoch="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    now=$(date +%s)
    [ "$now" -ge "$boot_epoch" ] || return 1
    printf '%s\n' "$((now - boot_epoch))"
}

session_suppression_reason() {
    local uptime_seconds lock_state
    lock_state=$(session_lock_state)
    if [ "$lock_state" = "locked" ]; then
        printf 'the macOS session is locked'
        return 0
    fi
    if [ "$lock_state" = "unknown" ]; then
        printf 'the macOS login or lock state is not safely available'
        return 0
    fi
    if [ "${STARTUP_GRACE_SECONDS:-300}" -gt 0 ]; then
        uptime_seconds=$(system_uptime_seconds) || uptime_seconds=""
        if [[ "$uptime_seconds" =~ ^[0-9]+$ ]] && \
            [ "$uptime_seconds" -lt "$STARTUP_GRACE_SECONDS" ]; then
            printf 'the Mac is still in its %s-second startup quiet period' "$STARTUP_GRACE_SECONDS"
            return 0
        fi
    fi
    return 1
}

baseline_current_state() {
    local alert baseline_level="" baseline_type=""
    for alert in "${ALERTS[@]}"; do
        parse_alert_entry "$alert"
        if [ "$PARSED_LVL" = "$BATTERY_PERCENT" ] && rule_applies_to_mode "$PARSED_TYP"; then
            baseline_level="$PARSED_LVL"
            baseline_type="$PARSED_TYP"
            break
        fi
    done
    write_state "$BATTERY_PERCENT" "$baseline_level" "$baseline_type" \
        "$BATTERY_MODE" "$BATTERY_SOURCE" 0
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
        [ "$MEDIA_WAS_PLAYING" -eq 1 ] || AUDIO_MODIFIED=0
        INTERRUPT_REASON="Mute key"
        return 0
    fi
    if [ "$current_volume" -lt "$ACTIVE_ALERT_VOL" ]; then
        USER_SILENCED=1
        [ "$MEDIA_WAS_PLAYING" -eq 1 ] || AUDIO_MODIFIED=0
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

adapter_connection_state() {
    # pmset can briefly lag behind a physical USB-C/MagSafe transition. The
    # battery registry exposes the adapter connection independently, allowing
    # an active sentence to be stopped as soon as the hardware reports it.
    ioreg -r -n AppleSmartBattery -w 0 -l 2>/dev/null | LC_ALL=C awk '
        /"ExternalConnected"[[:space:]]*=[[:space:]]*(Yes|true|1)/ {
            print "connected"
            exit
        }
        /"ExternalConnected"[[:space:]]*=[[:space:]]*(No|false|0)/ {
            print "disconnected"
            exit
        }
    '
}

poll_for_interrupt() {
    local type="$1" start_source="$2" adapter_state
    adapter_state=$(adapter_connection_state)
    if [ "$type" = "LOW" ] && [ "$start_source" = "BATTERY" ] && \
        [ "$adapter_state" = "connected" ]; then
        INTERRUPT_REASON="charger connected"
        return 0
    fi
    if [ "$type" = "HIGH" ] && [ "$adapter_state" = "disconnected" ]; then
        INTERRUPT_REASON="charger disconnected"
        return 0
    fi
    if get_battery_state && power_should_cutoff "$type" "$start_source"; then
        return 0
    fi
    check_user_silenced_audio
}

watch_alert_interrupts() {
    local type="$1" start_source="$2" check_seconds="$3"
    # This worker only reports a cutoff; the main process owns speech and audio cleanup.
    trap - EXIT INT TERM HUP
    while true; do
        if poll_for_interrupt "$type" "$start_source"; then
            printf '%s|%s\n' "$INTERRUPT_REASON" "$USER_SILENCED" > "$ALERT_WATCH_DIR/cutoff.tmp"
            mv -f "$ALERT_WATCH_DIR/cutoff.tmp" "$ALERT_WATCH_DIR/cutoff"
            return 0
        fi
        /bin/sleep "$check_seconds"
    done
}

alert_watch_cutoff() {
    [ -n "$ALERT_WATCH_DIR" ] && [ -f "$ALERT_WATCH_DIR/cutoff" ] || return 1
    IFS='|' read -r INTERRUPT_REASON USER_SILENCED < "$ALERT_WATCH_DIR/cutoff"
    return 0
}

speak_rule() {
    local message="$1" type="$2" repeat_count="$3" delay_ms="$4" rule_level="$5"
    local start_source="$BATTERY_SOURCE"
    local poll_ms poll_seconds check_seconds repetition pause_elapsed pause_step pause_seconds spoken_message

    poll_ms="$CHECK_INTERVAL_MS"
    # A short requested pause must not inherit a longer speech-completion poll.
    [ "$poll_ms" -gt "$delay_ms" ] && poll_ms="$delay_ms"
    poll_seconds=$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms / 1000 }')
    check_seconds=$(awk -v ms="$CHECK_INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')

    pause_active_media
    prepare_audio
    ALERT_WATCH_DIR=$(mktemp -d "$BATTMON_RUNTIME_DIR/.alert-watch.XXXXXX") || return 1
    watch_alert_interrupts "$type" "$start_source" "$check_seconds" &
    ALERT_WATCH_PID=$!
    if [ "$repeat_count" -eq 0 ]; then
        log_event "[Alert Started] Rule ${rule_level}% ${type}; until interrupted; ${delay_ms}ms pause"
    else
        log_event "[Alert Started] Rule ${rule_level}% ${type}; ${repeat_count} repeats; ${delay_ms}ms pause"
    fi

    repetition=1
    while [ "$repeat_count" -eq 0 ] || [ "$repetition" -le "$repeat_count" ]; do
        if get_battery_state && power_should_cutoff "$type" "$start_source"; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON before repetition $repetition"
            return 2
        fi
        if [ "$repetition" -eq 1 ] && check_user_silenced_audio; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON before repetition $repetition"
            return 2
        fi
        if alert_watch_cutoff; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON before repetition $repetition"
            return 2
        fi

        spoken_message=$(format_speech_message "$message" "$rule_level" "${BATTERY_PERCENT:-$rule_level}")
        if [ "$repeat_count" -eq 0 ]; then
            log_event "[Repetition ${repetition}/unlimited] Battery ${BATTERY_PERCENT:-unknown}%"
        else
            log_event "[Repetition ${repetition}/${repeat_count}] Battery ${BATTERY_PERCENT:-unknown}%"
        fi
        say "$spoken_message" &
        SAY_PID=$!

        while kill -0 "$SAY_PID" 2>/dev/null; do
            if alert_watch_cutoff; then
                log_event "[Alert Cutoff] $INTERRUPT_REASON during repetition $repetition"
                stop_speech
                return 2
            fi
            sleep "$poll_seconds"
        done
        wait "$SAY_PID" 2>/dev/null || true
        SAY_PID=""
        if alert_watch_cutoff; then
            log_event "[Alert Cutoff] $INTERRUPT_REASON after repetition $repetition"
            return 2
        fi

        pause_elapsed=0
        while [ "$pause_elapsed" -lt "$delay_ms" ] && \
            { [ "$repeat_count" -eq 0 ] || [ "$repetition" -lt "$repeat_count" ]; }; do
            if alert_watch_cutoff; then
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
    local alert level type exact=0 crossed=0

    for alert in "${ALERTS[@]}"; do
        parse_alert_entry "$alert"
        level="$PARSED_LVL"
        type="$PARSED_TYP"
        rule_applies_to_mode "$type" || continue

        exact=0
        crossed=0

        # A matching percentage is only a trigger when the battery reached it
        # in the rule's direction. A charger change at the same percentage is
        # not enough to create an alert.
        if [ "$BATTERY_PERCENT" -eq "$level" ]; then
            if [ -z "$LAST_PERCENT" ]; then
                exact=1
            elif [ "$type" = "LOW" ] && [ "$LAST_PERCENT" -gt "$BATTERY_PERCENT" ]; then
                exact=1
            elif [ "$type" = "HIGH" ] && [ "$LAST_PERCENT" -lt "$BATTERY_PERCENT" ]; then
                exact=1
            fi
        fi

        if [ -n "$LAST_PERCENT" ]; then
            if [ "$type" = "LOW" ] && [ "$BATTERY_PERCENT" -lt "$level" ] && [ "$LAST_PERCENT" -gt "$level" ]; then
                crossed=1
            elif [ "$type" = "HIGH" ] && [ "$BATTERY_PERCENT" -gt "$level" ] && [ "$LAST_PERCENT" -lt "$level" ]; then
                crossed=1
            fi
        fi

        if [ "$exact" -eq 0 ] && [ "$crossed" -eq 0 ]; then
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

print_media_control_guidance() {
    local controller_name="your terminal app"
    case "${TERM_PROGRAM:-}" in
        iTerm.app) controller_name="iTerm2" ;;
        Apple_Terminal) controller_name="Terminal" ;;
        WarpTerminal) controller_name="Warp" ;;
        vscode) controller_name="Visual Studio Code" ;;
    esac
    if [ "${#MEDIA_NATIVE_WARNINGS[@]}" -gt 0 ]; then
        printf 'Battmon found but could not control: %s\n' "${MEDIA_NATIVE_WARNINGS[*]}"
        echo "Open System Settings > Privacy & Security > Automation."
        printf 'Allow %s to control the player, then retry.\n' "$controller_name"
    fi
    if [ "${#MEDIA_BROWSER_WARNINGS[@]}" -gt 0 ]; then
        printf 'Battmon could not inspect browser media in: %s\n' "${MEDIA_BROWSER_WARNINGS[*]}"
        echo "For Chrome or Brave: View > Developer > Allow JavaScript from Apple Events."
        echo "For Safari: Develop > Allow JavaScript from Apple Events."
        echo "If macOS asks for Automation permission, choose Allow, then retry the test."
    fi
}

check_native_media_permission() {
    local process_name="$1" app_name="$2" probe_type="$3"
    if ! media_app_running "$process_name"; then
        printf ' [SKIP] %-18s Not running; open it and check again.\n' "$app_name"
        return 0
    fi

    if [ "$probe_type" = "quicktime" ]; then
        if osascript \
            -e 'with timeout of 2 seconds' \
            -e "tell application \"$app_name\" to count documents" \
            -e 'end timeout' >/dev/null 2>&1; then
            printf ' [READY] %-17s Battmon can control it.\n' "$app_name"
        else
            printf ' [BLOCKED] %-15s Allow Automation access in System Settings.\n' "$app_name"
        fi
    elif osascript \
        -e 'with timeout of 2 seconds' \
        -e "tell application \"$app_name\" to get player state" \
        -e 'end timeout' >/dev/null 2>&1; then
        printf ' [READY] %-17s Battmon can control it.\n' "$app_name"
    else
        printf ' [BLOCKED] %-15s Allow Automation access in System Settings.\n' "$app_name"
    fi
}

check_chromium_media_permission() {
    local process_name="$1" app_name="$2" result attempted_count error_count
    if ! media_app_running "$process_name"; then
        printf ' [SKIP] %-18s Not running; open it and check again.\n' "$app_name"
        return 0
    fi

    result=$(osascript \
        -e 'on run argv' \
        -e 'set probeScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e "tell application \"$app_name\"" \
        -e 'set attemptedCount to 0' \
        -e 'set errorCount to 0' \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then' \
        -e 'set attemptedCount to attemptedCount + 1' \
        -e 'execute browserTab javascript probeScript' \
        -e 'end if' \
        -e 'on error' \
        -e 'set errorCount to errorCount + 1' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'return (attemptedCount as text) & ":" & (errorCount as text)' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_PERMISSION_JS" 2>/dev/null) || result="blocked"

    if [ "$result" = "blocked" ]; then
        printf ' [BLOCKED] %-15s Allow Automation and JavaScript from Apple Events.\n' "$app_name"
        return 0
    fi
    IFS=: read -r attempted_count error_count <<< "$result"
    if ! [[ "$attempted_count" =~ ^[0-9]+$ ]] || ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
        printf ' [BLOCKED] %-15s Could not verify browser control.\n' "$app_name"
    elif [ "$attempted_count" -eq 0 ]; then
        printf ' [CHECK] %-17s Open a normal website tab and check again.\n' "$app_name"
    elif [ "$error_count" -ge "$attempted_count" ]; then
        printf ' [BLOCKED] %-15s Enable JavaScript from Apple Events.\n' "$app_name"
    else
        printf ' [READY] %-17s Battmon can inspect media tabs.\n' "$app_name"
    fi
}

check_safari_media_permission() {
    local result attempted_count error_count
    if ! media_app_running "Safari"; then
        printf ' [SKIP] %-18s Not running; open it and check again.\n' "Safari"
        return 0
    fi

    result=$(osascript \
        -e 'on run argv' \
        -e 'set probeScript to item 1 of argv' \
        -e 'with timeout of 5 seconds' \
        -e 'tell application "Safari"' \
        -e 'set attemptedCount to 0' \
        -e 'set errorCount to 0' \
        -e 'repeat with browserWindow in windows' \
        -e 'repeat with browserTab in tabs of browserWindow' \
        -e 'try' \
        -e 'set tabURL to URL of browserTab' \
        -e 'if tabURL starts with "http" then' \
        -e 'set attemptedCount to attemptedCount + 1' \
        -e 'do JavaScript probeScript in browserTab' \
        -e 'end if' \
        -e 'on error' \
        -e 'set errorCount to errorCount + 1' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'return (attemptedCount as text) & ":" & (errorCount as text)' \
        -e 'end tell' \
        -e 'end timeout' \
        -e 'end run' -- "$BROWSER_PERMISSION_JS" 2>/dev/null) || result="blocked"

    if [ "$result" = "blocked" ]; then
        printf ' [BLOCKED] %-15s Allow Automation and JavaScript from Apple Events.\n' "Safari"
        return 0
    fi
    IFS=: read -r attempted_count error_count <<< "$result"
    if ! [[ "$attempted_count" =~ ^[0-9]+$ ]] || ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
        printf ' [BLOCKED] %-15s Could not verify browser control.\n' "Safari"
    elif [ "$attempted_count" -eq 0 ]; then
        printf ' [CHECK] %-17s Open a normal website tab and check again.\n' "Safari"
    elif [ "$error_count" -ge "$attempted_count" ]; then
        printf ' [BLOCKED] %-15s Enable JavaScript from Apple Events.\n' "Safari"
    else
        printf ' [READY] %-17s Battmon can inspect media tabs.\n' "Safari"
    fi
}

run_media_permission_check() {
    local lock_result
    acquire_monitor_lock
    lock_result=$?
    if [ "$lock_result" -eq 2 ]; then
        echo "An alert or monitor check is running. Try this permission check again shortly."
        return 2
    elif [ "$lock_result" -ne 0 ]; then
        echo "Battmon could not start the permission check."
        return 1
    fi

    echo "Checking media control. macOS may ask you to allow access."
    echo "This check does not pause, play, or change the volume of any media."
    echo ""
    check_native_media_permission "Music" "Music" player
    check_native_media_permission "Spotify" "Spotify" player
    check_native_media_permission "QuickTime Player" "QuickTime Player" quicktime
    check_chromium_media_permission "Google Chrome" "Google Chrome"
    check_chromium_media_permission "Brave Browser" "Brave Browser"
    check_chromium_media_permission "Microsoft Edge" "Microsoft Edge"
    check_chromium_media_permission "Vivaldi" "Vivaldi"
    check_chromium_media_permission "Chromium" "Chromium"
    check_safari_media_permission
    echo ""
    echo "For BLOCKED native apps: System Settings > Privacy & Security > Automation."
    echo "For Chrome/Brave/Edge: View > Developer > Allow JavaScript from Apple Events."
    echo "For Safari: Develop > Allow JavaScript from Apple Events."
    release_monitor_lock
}

run_media_test() {
    local lock_result speech_result test_message
    acquire_monitor_lock
    lock_result=$?
    if [ "$lock_result" -eq 2 ]; then
        printf 'Battmon monitor process %s is still active, so the media test cannot overlap it.\n' \
            "${MONITOR_LOCK_OWNER_PID:-unknown}"
        echo "If an alert is speaking, stop it with Mute, Volume Down, or the charger."
        echo "If nothing is speaking, run 'battmon stop' once, then retry this test."
        return 2
    elif [ "$lock_result" -ne 0 ]; then
        echo "Battmon could not start the media test."
        return 1
    fi

    load_config || {
        echo "Battmon could not load its settings."
        return 1
    }
    if [ "${PAUSE_MEDIA:-true}" != "true" ]; then
        echo "Media pausing is turned off. Enable it in Audio & media settings first."
        return 3
    fi

    pause_active_media
    if [ "$MEDIA_WAS_PLAYING" -ne 1 ]; then
        print_media_control_guidance
        echo "No controllable playing media was found."
        echo "Start playback in a supported app or browser tab, then retry."
        return 3
    fi

    print_media_control_guidance
    prepare_audio
    printf 'Paused: %s\n' "${MEDIA_PAUSED_APPS[*]}"
    echo "Speaking the test message now..."
    test_message="Battmon media test. Your music will resume now."
    log_event "[Media Test] Started for ${MEDIA_PAUSED_APPS[*]}"
    say "$test_message" &
    SAY_PID=$!
    wait "$SAY_PID"
    speech_result=$?
    SAY_PID=""

    restore_audio
    resume_paused_media
    release_monitor_lock
    if [ "$speech_result" -eq 0 ]; then
        echo "Media test complete. Original volume restored and playback resumed."
    else
        echo "The test voice failed, but Battmon still restored your media."
    fi
    return "$speech_result"
}

main() {
    local lock_result speech_result suppression_reason
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

    if suppression_reason=$(session_suppression_reason); then
        write_state "$BATTERY_PERCENT" "" "" "$BATTERY_MODE" "$BATTERY_SOURCE" 1 || \
            log_event "[Warning] Could not persist quiet-session state"
        log_event "[Alert Suppressed] $suppression_reason"
        exit 0
    fi
    if [ "$LAST_SESSION_BLOCKED" -eq 1 ]; then
        baseline_current_state || log_event "[Warning] Could not persist post-unlock baseline"
        log_event "[Alert Suppressed] Session is active again; current battery state was used as a quiet baseline"
        exit 0
    fi

    if [ "${#ALERT_TIMES[@]}" -gt 0 ] && alert_time_is_quiet_now; then
        baseline_current_state || log_event "[Warning] Could not persist quiet-time baseline"
        log_event "[Alert Suppressed] Quiet time is active; current battery state was used as a silent baseline"
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
    stop_alert_watch
    # Charger, power-mode, mute, and volume-key cutoffs are expected outcomes.
    [ "$speech_result" -eq 2 ] && return 0
    return "$speech_result"
}

if [ "${1:-}" = "--test-media" ]; then
    run_media_test
    exit $?
fi

if [ "${1:-}" = "--check-media-permissions" ]; then
    run_media_permission_check
    exit $?
fi

main "$@"
