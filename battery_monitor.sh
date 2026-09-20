#!/bin/bash
# ==============================================================================
# Battmon - Battery Monitor Background Engine
# Universal for any macOS machine
# ==============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$DIR/battery_config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$HOME/.battmon/battery_config.sh"
fi
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$HOME/.batmon/battery_config.sh"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi

source "$CONFIG_FILE"

REPEAT_COUNT="${REPEAT_COUNT:-10}"
REPEAT_DELAY_MS="${REPEAT_DELAY_MS:-100}"
CHECK_INTERVAL_MS="${CHECK_INTERVAL_MS:-200}"
ALERT_VOLUME="${ALERT_VOLUME:-60}"
RESTORE_VOLUME=true

ORIG_VOL=""
ORIG_MUTED=""
ACTIVE_ALERT_VOL=""
VOL_MODIFIED=0

get_audio_settings() {
    osascript -e "get {output volume, output muted} of (get volume settings)" 2>/dev/null | tr -d ','
}

set_sys_volume() {
    local v="$1"
    osascript -e "set volume output volume $v" 2>/dev/null || true
}

set_sys_muted() {
    local m="$1"
    osascript -e "set volume output muted $m" 2>/dev/null || true
}

prepare_volume() {
    local target_vol="${ALERT_VOLUME:-60}"
    local audio_info
    audio_info=$(get_audio_settings)
    ORIG_VOL=$(echo "$audio_info" | awk '{print $1}')
    ORIG_MUTED=$(echo "$audio_info" | awk '{print $2}')
    ORIG_VOL="${ORIG_VOL:-50}"
    ORIG_MUTED="${ORIG_MUTED:-false}"

    local need_change=0
    if [ "$ORIG_MUTED" = "true" ]; then
        set_sys_muted false
        need_change=1
    fi

    if [ "$ORIG_VOL" -lt "$target_vol" ]; then
        set_sys_volume "$target_vol"
        need_change=1
        ACTIVE_ALERT_VOL="$target_vol"
    else
        ACTIVE_ALERT_VOL="$ORIG_VOL"
    fi

    if [ $need_change -eq 1 ]; then
        VOL_MODIFIED=1
    fi
}

restore_volume() {
    if [ $VOL_MODIFIED -eq 1 ]; then
        if [ -n "$ORIG_VOL" ]; then
            set_sys_volume "$ORIG_VOL"
        fi
        if [ "$ORIG_MUTED" = "true" ]; then
            set_sys_muted true
        fi
        VOL_MODIFIED=0
    fi
}

LOCK_DIR="/tmp/battmon.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0
    else
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    fi
fi
echo $$ > "$LOCK_DIR/pid"

trap 'restore_volume; rm -rf "$LOCK_DIR"' EXIT INT TERM

STATE_FILE="$HOME/.battmon_state"

is_ac_power() {
    pmset -g batt | grep -q 'AC Power'
}

BATT_INFO=$(pmset -g batt)
PERCENT=$(echo "$BATT_INFO" | grep -Eo "[0-9]+%" | head -n 1 | tr -d '%')

if [ -z "$PERCENT" ] || ! [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
    exit 0
fi

LAST_PERCENT=""
LAST_ALERTED_LEVEL=""
LAST_ALERTED_TYPE=""
if [ -f "$STATE_FILE" ]; then
    IFS=":" read -r LAST_PERCENT LAST_ALERTED_LEVEL LAST_ALERTED_TYPE < "$STATE_FILE" 2>/dev/null
fi

format_speech_msg() {
    local raw_msg="$1"
    local lvl="$2"
    local cur="$3"
    local res="$raw_msg"

    res="${res//\{percent\}/$cur}"
    res="${res//\{level\}/$cur}"
    res="${res//\{pct\}/$cur}"

    if [ -n "$lvl" ] && [[ "$cur" =~ ^[0-9]+$ ]] && [ "$lvl" -ne "$cur" ]; then
        res="${res//${lvl} percent/${cur} percent}"
        res="${res//${lvl} Percent/${cur} Percent}"
        res="${res//${lvl}%/${cur}%}"
        res="${res//at ${lvl}/at ${cur}}"
        res="${res//is ${lvl}/is ${cur}}"
        res=$(echo "$res" | sed -E "s/(^|[[:space:]])${lvl}([[:space:]]|%|\$)/\1${cur}\2/g")
    fi
    echo "$res"
}

repeat_speech() {
    local base_msg="$1"
    local type="$2"
    local count="$3"
    local delay_ms="$4"
    local check_ms="$5"
    local rule_level="$6"

    local speak_check_sec
    speak_check_sec=$(awk -v ms="$check_ms" 'BEGIN { printf "%.3f", ms / 1000 }')

    local pause_poll_ms="$check_ms"
    if [ "$delay_ms" -lt "$pause_poll_ms" ]; then
        pause_poll_ms="$delay_ms"
    fi
    local pause_check_sec
    pause_check_sec=$(awk -v ms="$pause_poll_ms" 'BEGIN { printf "%.3f", ms / 1000 }')
    local pause_check_count
    pause_check_count=$(awk -v d="$delay_ms" -v p="$pause_poll_ms" 'BEGIN { r = int(d / p); if (r < 1) r = 1; print r }')

    prepare_volume
    echo "[$(date '+%H:%M:%S')] [Alert Started] Rule ${rule_level}% (${type}) | ${count}x repeat | ${delay_ms}ms pause" >> /tmp/battmon.log

    for ((i=1; i<=count; i++)); do
        if [ "$type" = "LOW" ] && is_ac_power; then
            echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger connected before rep $i" >> /tmp/battmon.log
            return 0
        fi
        if [ "$type" = "HIGH" ] && ! is_ac_power; then
            echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger disconnected before rep $i" >> /tmp/battmon.log
            return 0
        fi

        local live_pct
        live_pct=$(pmset -g batt | grep -Eo "[0-9]+%" | head -n 1 | tr -d '%')
        if [ -z "$live_pct" ] || ! [[ "$live_pct" =~ ^[0-9]+$ ]]; then
            live_pct="${rule_level:-$PERCENT}"
        fi

        local spoken_msg
        spoken_msg=$(format_speech_msg "$base_msg" "$rule_level" "$live_pct")

        echo "$live_pct:$rule_level:$type" > "$STATE_FILE"
        echo "[$(date '+%H:%M:%S')] [Rep $i/$count] Speaking: \"$spoken_msg\" (Battery: ${live_pct}%)" >> /tmp/battmon.log

        local audio_check
        audio_check=$(get_audio_settings)
        local cur_v cur_m
        cur_v=$(echo "$audio_check" | awk '{print $1}')
        cur_m=$(echo "$audio_check" | awk '{print $2}')
        if [ "$cur_m" = "true" ]; then
            echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via MUTE before speaking rep $i" >> /tmp/battmon.log
            VOL_MODIFIED=0
            return 0
        fi
        if [[ "$cur_v" =~ ^[0-9]+$ ]] && [ -n "$ACTIVE_ALERT_VOL" ] && [ "$cur_v" -le "$((ACTIVE_ALERT_VOL - 6))" ]; then
            echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via VOLUME DOWN before speaking rep $i ($cur_v% <= $((ACTIVE_ALERT_VOL - 6))%)" >> /tmp/battmon.log
            VOL_MODIFIED=0
            return 0
        fi

        say "$spoken_msg" &
        local say_pid=$!

        while kill -0 "$say_pid" 2>/dev/null; do
            if [ "$type" = "LOW" ] && is_ac_power; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger connected while speaking rep $i" >> /tmp/battmon.log
                kill -9 "$say_pid" 2>/dev/null
                wait "$say_pid" 2>/dev/null
                return 0
            fi
            if [ "$type" = "HIGH" ] && ! is_ac_power; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger disconnected while speaking rep $i" >> /tmp/battmon.log
                kill -9 "$say_pid" 2>/dev/null
                wait "$say_pid" 2>/dev/null
                return 0
            fi

            audio_check=$(get_audio_settings)
            cur_v=$(echo "$audio_check" | awk '{print $1}')
            cur_m=$(echo "$audio_check" | awk '{print $2}')

            if [ "$cur_m" = "true" ]; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via MUTE while speaking rep $i" >> /tmp/battmon.log
                kill -9 "$say_pid" 2>/dev/null
                wait "$say_pid" 2>/dev/null
                VOL_MODIFIED=0
                return 0
            fi
            if [[ "$cur_v" =~ ^[0-9]+$ ]] && [ -n "$ACTIVE_ALERT_VOL" ] && [ "$cur_v" -le "$((ACTIVE_ALERT_VOL - 6))" ]; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via VOLUME DOWN while speaking rep $i ($cur_v% <= $((ACTIVE_ALERT_VOL - 6))%)" >> /tmp/battmon.log
                kill -9 "$say_pid" 2>/dev/null
                wait "$say_pid" 2>/dev/null
                VOL_MODIFIED=0
                return 0
            fi

            sleep "$speak_check_sec"
        done

        for ((c=0; c<pause_check_count; c++)); do
            if [ "$type" = "LOW" ] && is_ac_power; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger connected during pause after rep $i" >> /tmp/battmon.log
                return 0
            fi
            if [ "$type" = "HIGH" ] && ! is_ac_power; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Charger disconnected during pause after rep $i" >> /tmp/battmon.log
                return 0
            fi

            audio_check=$(get_audio_settings)
            cur_v=$(echo "$audio_check" | awk '{print $1}')
            cur_m=$(echo "$audio_check" | awk '{print $2}')

            if [ "$cur_m" = "true" ]; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via MUTE during pause after rep $i" >> /tmp/battmon.log
                VOL_MODIFIED=0
                return 0
            fi
            if [[ "$cur_v" =~ ^[0-9]+$ ]] && [ -n "$ACTIVE_ALERT_VOL" ] && [ "$cur_v" -le "$((ACTIVE_ALERT_VOL - 6))" ]; then
                echo "[$(date '+%H:%M:%S')] [Alert Cutoff] Silenced via VOLUME DOWN during pause after rep $i ($cur_v% <= $((ACTIVE_ALERT_VOL - 6))%)" >> /tmp/battmon.log
                VOL_MODIFIED=0
                return 0
            fi

            sleep "$pause_check_sec"
        done
    done
    echo "[$(date '+%H:%M:%S')] [Alert Finished] Successfully completed all $count repetitions." >> /tmp/battmon.log
}

for ALERT in "${ALERTS[@]}"; do
    IFS=":" read -r p1 p2 p3 p4 p5 <<< "$ALERT"

    if [ -n "$p5" ]; then
        LEVEL="$p1"
        TYPE="$p2"
        ALERT_REPEAT="${p3:-$REPEAT_COUNT}"
        ALERT_DELAY="${p4:-$REPEAT_DELAY_MS}"
        MSG="$p5"
    elif [ -n "$p3" ]; then
        LEVEL="$p1"
        TYPE="$p2"
        ALERT_REPEAT="$REPEAT_COUNT"
        ALERT_DELAY="$REPEAT_DELAY_MS"
        MSG="$p3"
    else
        continue
    fi

    should_trigger=0
    if [ "$PERCENT" -eq "$LEVEL" ]; then
        should_trigger=1
    elif [ "$TYPE" = "LOW" ] && [ -n "$LAST_PERCENT" ] && [ "$PERCENT" -lt "$LEVEL" ] && [ "$LAST_PERCENT" -gt "$LEVEL" ]; then
        # Battery dropped past this threshold between checks (e.g. from 26% to 24%)
        should_trigger=1
    elif [ "$TYPE" = "HIGH" ] && [ -n "$LAST_PERCENT" ] && [ "$PERCENT" -gt "$LEVEL" ] && [ "$LAST_PERCENT" -lt "$LEVEL" ]; then
        # Battery charged past this threshold between checks
        should_trigger=1
    fi

    if [ "$should_trigger" -eq 1 ]; then
        if [ "$TYPE" = "HIGH" ] && ! is_ac_power; then continue; fi
        if [ "$TYPE" = "LOW" ] && is_ac_power; then continue; fi

        if [ "$PERCENT" = "$LAST_PERCENT" ] && [ "$LEVEL" = "$LAST_ALERTED_LEVEL" ] && [ "$TYPE" = "$LAST_ALERTED_TYPE" ]; then
            exit 0
        fi

        repeat_speech "$MSG" "$TYPE" "$ALERT_REPEAT" "$ALERT_DELAY" "$CHECK_INTERVAL_MS" "$LEVEL"
        echo "$PERCENT:$LEVEL:$TYPE" > "$STATE_FILE"
        exit 0
    fi
done

echo "$PERCENT::" > "$STATE_FILE"
exit 0
