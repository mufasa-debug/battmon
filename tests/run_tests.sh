#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BIN="$ROOT_DIR/tests/bin"
TEST_ROOT=$(mktemp -d /private/tmp/battmon-tests.XXXXXX) || exit 1
ORIGINAL_PATH="$PATH"
PASS_COUNT=0
FAIL_COUNT=0

cleanup_tests() {
    rm -rf "$TEST_ROOT"
}
trap cleanup_tests EXIT INT TERM

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$1" >&2
}

assert_true() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

new_case() {
    CASE_HOME=$(mktemp -d "$TEST_ROOT/case.XXXXXX") || exit 1
    mkdir -p "$CASE_HOME/.battmon"
    SAY_LOG="$CASE_HOME/say.log"
    EVENT_LOG="$CASE_HOME/events.log"
    : > "$SAY_LOG"
    : > "$EVENT_LOG"
}

write_config() {
    local path="$1"
    shift
    {
        printf 'REPEAT_COUNT=1\n'
        printf 'REPEAT_DELAY_MS=100\n'
        printf 'CHECK_INTERVAL_MS=50\n'
        printf 'STARTUP_GRACE_SECONDS=300\n'
        printf 'ALERT_VOLUME=60\n'
        printf 'RESTORE_VOLUME=true\n'
        printf 'PAUSE_MEDIA=%s\n' "${CONFIG_PAUSE_MEDIA:-true}"
        printf 'ALERTS=(\n'
        local rule
        for rule in "$@"; do
            printf '    %q\n' "$rule"
        done
        printf ')\n'
    } > "$path"
    chmod 600 "$path"
}

write_state() {
    local path="$1" percent="$2" level="$3" type="$4" mode="$5" source="$6"
    {
        printf 'LAST_PERCENT=%s\n' "$percent"
        printf 'LAST_ALERT_LEVEL=%s\n' "$level"
        printf 'LAST_ALERT_TYPE=%s\n' "$type"
        printf 'LAST_MODE=%s\n' "$mode"
        printf 'LAST_SOURCE=%s\n' "$source"
    } > "$path"
}

run_monitor() {
    env HOME="$CASE_HOME" \
        PATH="$TEST_BIN:$ORIGINAL_PATH" \
        BATTMON_RUNTIME_DIR="$CASE_HOME/.battmon" \
        BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
        BATTMON_STATE_FILE="$CASE_HOME/.battmon/state" \
        BATTMON_LOG_DIR="$CASE_HOME/logs" \
        BATTMON_LOG_FILE="$CASE_HOME/logs/battmon.log" \
        TEST_SAY_LOG="$SAY_LOG" \
        TEST_EVENT_LOG="$EVENT_LOG" \
        TEST_POWER_SOURCE="${TEST_POWER_SOURCE:-Battery}" \
        TEST_BATTERY_PERCENT="${TEST_BATTERY_PERCENT:-50}" \
        TEST_BATTERY_MODE="${TEST_BATTERY_MODE:-discharging}" \
        TEST_NO_BATTERY="${TEST_NO_BATTERY:-0}" \
        TEST_AUDIO_FAIL="${TEST_AUDIO_FAIL:-0}" \
        TEST_AUDIO_VOLUME=80 \
        TEST_AUDIO_MUTED=false \
        TEST_RUNNING_MEDIA_APPS="${TEST_RUNNING_MEDIA_APPS:-}" \
        TEST_MUSIC_STATE="${TEST_MUSIC_STATE:-paused}" \
        TEST_SPOTIFY_STATE="${TEST_SPOTIFY_STATE:-paused}" \
        TEST_QUICKTIME_STATE="${TEST_QUICKTIME_STATE:-paused}" \
        TEST_INTERRUPT_AFTER_SAYS="${TEST_INTERRUPT_AFTER_SAYS:-0}" \
        TEST_INTERRUPT_FLAG="${TEST_INTERRUPT_FLAG:-$CASE_HOME/interrupt.flag}" \
        TEST_INTERRUPTED_AUDIO_VOLUME="${TEST_INTERRUPTED_AUDIO_VOLUME:-70}" \
        TEST_INTERRUPTED_AUDIO_MUTED="${TEST_INTERRUPTED_AUDIO_MUTED:-false}" \
        TEST_SESSION_LOCKED="${TEST_SESSION_LOCKED:-0}" \
        TEST_SESSION_STATE_UNKNOWN="${TEST_SESSION_STATE_UNKNOWN:-0}" \
        TEST_IOREG_LARGE_OUTPUT="${TEST_IOREG_LARGE_OUTPUT:-0}" \
        TEST_SYSTEM_UPTIME_SECONDS="${TEST_SYSTEM_UPTIME_SECONDS:-86400}" \
        TEST_CHROME_MEDIA_COUNT="${TEST_CHROME_MEDIA_COUNT:-0}" \
        TEST_BRAVE_MEDIA_COUNT="${TEST_BRAVE_MEDIA_COUNT:-0}" \
        TEST_SAFARI_MEDIA_COUNT="${TEST_SAFARI_MEDIA_COUNT:-0}" \
        TEST_CHROME_CONTROL_FAIL="${TEST_CHROME_CONTROL_FAIL:-0}" \
        TEST_BRAVE_CONTROL_FAIL="${TEST_BRAVE_CONTROL_FAIL:-0}" \
        TEST_SAFARI_CONTROL_FAIL="${TEST_SAFARI_CONTROL_FAIL:-0}" \
        /bin/bash "$ROOT_DIR/battery_monitor.sh"
}

# Static validation.
if /bin/bash -n "$ROOT_DIR/battmon" "$ROOT_DIR/battmon_common.sh" \
    "$ROOT_DIR/battery_monitor.sh" "$ROOT_DIR/battery_config.sh" "$ROOT_DIR/setup.sh"; then
    pass "all shell files parse on Bash"
else
    fail "all shell files parse on Bash"
fi
assert_true "plist template is valid" plutil -lint "$ROOT_DIR/com.battery.batmon.plist"

# Exact low threshold and debounce.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
write_state "$CASE_HOME/.battmon/state" 11 "" "" discharging BATTERY
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=10 TEST_BATTERY_MODE=discharging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ] && grep -q '^ten percent$' "$SAY_LOG"; then
    pass "exact LOW threshold speaks once"
else
    fail "exact LOW threshold speaks once"
fi
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=10 TEST_BATTERY_MODE=discharging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ]; then
    pass "same threshold is debounced"
else
    fail "same threshold is debounced"
fi
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=10 TEST_BATTERY_MODE=discharging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ]; then
    pass "debounce marker survives repeated unchanged checks"
else
    fail "debounce marker survives repeated unchanged checks"
fi
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=9 TEST_BATTERY_MODE=discharging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ]; then
    pass "leaving an exact LOW threshold does not retrigger it"
else
    fail "leaving an exact LOW threshold does not retrigger it"
fi

# Large downward jump selects the most critical crossed rule.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" \
    "15:LOW:1:100:fifteen" "10:LOW:1:100:ten" "5:LOW:1:100:five"
write_state "$CASE_HOME/.battmon/state" 20 "" "" discharging BATTERY
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=4 TEST_BATTERY_MODE=discharging run_monitor
if grep -q '^five$' "$SAY_LOG" && ! grep -q '^fifteen$' "$SAY_LOG"; then
    pass "battery jump chooses most critical crossed threshold"
else
    fail "battery jump chooses most critical crossed threshold"
fi

# High thresholds use charging mode and choose the highest crossed rule.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" \
    "80:HIGH:1:100:eighty" "90:HIGH:1:100:ninety"
write_state "$CASE_HOME/.battmon/state" 70 "" "" charging AC
TEST_POWER_SOURCE=AC TEST_BATTERY_PERCENT=95 TEST_BATTERY_MODE=charging run_monitor
if grep -q '^ninety$' "$SAY_LOG" && ! grep -q '^eighty$' "$SAY_LOG"; then
    pass "charging jump chooses highest crossed threshold"
else
    fail "charging jump chooses highest crossed threshold"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "80:HIGH:1:100:eighty exact"
write_state "$CASE_HOME/.battmon/state" 79 "" "" charging AC
TEST_POWER_SOURCE=AC TEST_BATTERY_PERCENT=80 TEST_BATTERY_MODE=charging run_monitor
assert_true "exact HIGH threshold speaks while charging" grep -q '^eighty exact$' "$SAY_LOG"
TEST_POWER_SOURCE=AC TEST_BATTERY_PERCENT=81 TEST_BATTERY_MODE=charging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ]; then
    pass "leaving an exact HIGH threshold does not retrigger it"
else
    fail "leaving an exact HIGH threshold does not retrigger it"
fi

# An attached adapter does not hide a genuinely discharging battery.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "13:LOW:1:100:still discharging"
write_state "$CASE_HOME/.battmon/state" 14 "" "" discharging AC
TEST_POWER_SOURCE=AC TEST_BATTERY_PERCENT=13 TEST_BATTERY_MODE=discharging run_monitor
assert_true "LOW alert works while AC is attached but battery is discharging" grep -q '^still discharging$' "$SAY_LOG"

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "13:LOW:1:100:must stay quiet"
write_state "$CASE_HOME/.battmon/state" 14 "" "" charging AC
TEST_POWER_SOURCE=AC TEST_BATTERY_PERCENT=13 TEST_BATTERY_MODE=charging run_monitor
if [ ! -s "$SAY_LOG" ]; then
    pass "LOW alert is suppressed while charging"
else
    fail "LOW alert is suppressed while charging"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "0:LOW:1:100:invalid rule"
TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=10 TEST_BATTERY_MODE=discharging run_monitor >/dev/null 2>&1
invalid_config_result=$?
if [ "$invalid_config_result" -eq 2 ] && [ ! -s "$SAY_LOG" ] && \
    grep -q 'monitor run suppressed' "$CASE_HOME/logs/battmon.log"; then
    pass "an all-invalid rule set fails safely without default speech"
else
    fail "an all-invalid rule set fails safely without default speech"
fi

# Locked sessions and the cold-boot grace period create a quiet baseline.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "1:LOW:1:50:one percent"
write_state "$CASE_HOME/.battmon/state" 2 "" "" discharging BATTERY
TEST_SESSION_LOCKED=1 TEST_IOREG_LARGE_OUTPUT=1 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=1 \
    TEST_BATTERY_MODE=discharging run_monitor
locked_state_ok=0
if grep -q '^LAST_SESSION_BLOCKED=1$' "$CASE_HOME/.battmon/state" && [ ! -s "$SAY_LOG" ]; then
    locked_state_ok=1
fi
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=1 \
    TEST_BATTERY_MODE=discharging run_monitor
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=1 \
    TEST_BATTERY_MODE=discharging run_monitor
if [ "$locked_state_ok" -eq 1 ] && [ ! -s "$SAY_LOG" ] && \
    grep -q '^LAST_SESSION_BLOCKED=0$' "$CASE_HOME/.battmon/state" && \
    grep -q '^LAST_ALERT_LEVEL=1$' "$CASE_HOME/.battmon/state"; then
    pass "locked-session battery alerts stay silent and remain suppressed after unlock"
else
    fail "locked-session battery alerts stay silent and remain suppressed after unlock"
fi

TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=2 \
    TEST_BATTERY_MODE=discharging run_monitor
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=1 \
    TEST_BATTERY_MODE=discharging run_monitor
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "1" ]; then
    pass "alerts re-arm normally after leaving a lock-suppressed percentage"
else
    fail "alerts re-arm normally after leaving a lock-suppressed percentage"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:fifty percent"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=60 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=301 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
TEST_SESSION_LOCKED=0 TEST_SYSTEM_UPTIME_SECONDS=301 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
if [ ! -s "$SAY_LOG" ] && grep -q 'startup quiet period' "$CASE_HOME/logs/battmon.log"; then
    pass "cold-boot grace period suppresses immediate alerts after power-on"
else
    fail "cold-boot grace period suppresses immediate alerts after power-on"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:must fail quiet"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_SESSION_STATE_UNKNOWN=1 TEST_SYSTEM_UPTIME_SECONDS=86400 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
if [ ! -s "$SAY_LOG" ] && grep -q 'lock state is not safely available' "$CASE_HOME/logs/battmon.log"; then
    pass "unknown login state fails quiet instead of speaking unattended"
else
    fail "unknown login state fails quiet instead of speaking unattended"
fi

# Missing hardware data is quiet, and unavailable audio controls do not block speech.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:100:must stay quiet"
TEST_NO_BATTERY=1 TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 TEST_BATTERY_MODE=discharging run_monitor
if [ ! -s "$SAY_LOG" ] && grep -q 'No supported battery' "$CASE_HOME/logs/battmon.log"; then
    pass "missing battery exits quietly with diagnostics"
else
    fail "missing battery exits quietly with diagnostics"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:audio fallback"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_AUDIO_FAIL=1 TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 TEST_BATTERY_MODE=discharging run_monitor
if grep -q '^audio fallback$' "$SAY_LOG" && grep -q 'Audio state unavailable' "$CASE_HOME/logs/battmon.log"; then
    pass "audio-control failure falls back without suppressing alert"
else
    fail "audio-control failure falls back without suppressing alert"
fi

# Built-ins default to 100 ms while valid 50 ms user delays remain unchanged.
new_case
env HOME="$CASE_HOME" /bin/bash -c 'source "$1"; set_builtin_defaults; [ "$REPEAT_DELAY_MS" = 100 ]' _ \
    "$ROOT_DIR/battmon_common.sh"
if [ "$?" -eq 0 ]; then
    pass "built-in pause default is 100 ms"
else
    fail "built-in pause default is 100 ms"
fi
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:50:fifty millisecond delay"
env HOME="$CASE_HOME" BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
    /bin/bash -c 'source "$1"; load_config; parse_alert_entry "${ALERTS[0]}"; [ "$PARSED_DEL" = 50 ]' _ \
    "$ROOT_DIR/battmon_common.sh"
if [ "$?" -eq 0 ]; then
    pass "50 ms user pause is preserved"
else
    fail "50 ms user pause is preserved"
fi

# A per-rule repeat value of 0 means "keep speaking until interrupted".
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:0:50:keep speaking"
env HOME="$CASE_HOME" BATTMON_RUNTIME_DIR="$CASE_HOME/.battmon" \
    BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
    /bin/bash -c 'source "$1"; load_config || exit; parse_alert_entry "${ALERTS[0]}"; [ "$PARSED_REP" = 0 ] || exit 1; save_config >/dev/null; source "$BATTMON_CONFIG_FILE"; parse_alert_entry "${ALERTS[0]}"; [ "$PARSED_REP" = 0 ]' _ \
    "$ROOT_DIR/battmon_common.sh"
if [ "$?" -eq 0 ]; then
    pass "unlimited repeat mode survives config normalization and save"
else
    fail "unlimited repeat mode survives config normalization and save"
fi

# Unlimited speech stops on a user volume change, restores audio, then resumes
# only the media player Battmon actually paused.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:0:50:interrupt me"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_RUNNING_MEDIA_APPS=Spotify TEST_SPOTIFY_STATE=playing \
    TEST_INTERRUPT_AFTER_SAYS=3 TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=50 TEST_BATTERY_MODE=discharging run_monitor
event_sequence=$(tr '\n' '|' < "$EVENT_LOG")
if [ "$(wc -l < "$SAY_LOG" | tr -d ' ')" = "3" ] && \
    [[ "$event_sequence" == 'media:pause:Spotify|say:interrupt me|say:interrupt me|say:interrupt me|audio:restore|media:resume:Spotify|' ]]; then
    pass "unlimited alert pauses media, stops on Volume Down, restores, and resumes in order"
else
    fail "unlimited alert pauses media, stops on Volume Down, restores, and resumes in order"
fi

# Browser media is marked per element so only what Battmon paused is resumed.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:browser alert"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_RUNNING_MEDIA_APPS='Google Chrome,Brave Browser,Safari' \
    TEST_CHROME_MEDIA_COUNT=1 TEST_BRAVE_MEDIA_COUNT=2 TEST_SAFARI_MEDIA_COUNT=1 \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
event_sequence=$(tr '\n' '|' < "$EVENT_LOG")
if [[ "$event_sequence" == 'media:pause:Google Chrome|media:pause:Brave Browser|media:pause:Safari|say:browser alert|audio:restore|media:resume:Google Chrome|media:resume:Brave Browser|media:resume:Safari|' ]]; then
    pass "Chrome, Brave, and Safari media pause before speech and resume afterward"
else
    fail "Chrome, Brave, and Safari media pause before speech and resume afterward"
fi

# A running but already-paused player must be left alone.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:one alert"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_RUNNING_MEDIA_APPS=Spotify TEST_SPOTIFY_STATE=paused \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
if ! grep -q '^media:' "$EVENT_LOG" && grep -q '^one alert$' "$SAY_LOG"; then
    pass "already-paused media is neither paused nor resumed"
else
    fail "already-paused media is neither paused nor resumed"
fi

# The global media-interruption setting can disable player control.
new_case
CONFIG_PAUSE_MEDIA=false write_config "$CASE_HOME/.battmon/battery_config.sh" "50:LOW:1:50:no media control"
write_state "$CASE_HOME/.battmon/state" 51 "" "" discharging BATTERY
TEST_RUNNING_MEDIA_APPS=Spotify TEST_SPOTIFY_STATE=playing \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging run_monitor
if ! grep -q '^media:' "$EVENT_LOG" && grep -q '^no media control$' "$SAY_LOG"; then
    pass "disabled media interruption leaves a playing app untouched"
else
    fail "disabled media interruption leaves a playing app untouched"
fi

# Duplicate rules merge without losing either phrase.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" \
    "10:LOW:1:100:Battery is at 10 percent" "10:LOW:1:100:Charge up your battery"
env HOME="$CASE_HOME" BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
    /bin/bash -c 'source "$1"; load_config; printf "%s\n" "${ALERTS[@]}"' _ \
    "$ROOT_DIR/battmon_common.sh" > "$CASE_HOME/normalized.txt"
if grep -q 'Battery is at 10 percent. Charge up your battery' "$CASE_HOME/normalized.txt"; then
    pass "duplicate threshold messages merge deterministically"
else
    fail "duplicate threshold messages merge deterministically"
fi

# Generated configs escape shell metacharacters and remain valid.
new_case
env HOME="$CASE_HOME" BATTMON_RUNTIME_DIR="$CASE_HOME/.battmon" \
    BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
    BATTMON_TEMPLATE_CONFIG="$ROOT_DIR/battery_config.sh" \
    /bin/bash -c 'source "$1"; set_builtin_defaults; dangerous='"'"'Battery "$HOME" $(touch "$HOME/should-not-exist")'"'"'; ALERTS=("10:LOW:1:100:$dangerous"); CONFIG_LOADED_SIGNATURE=""; save_config >/dev/null' _ \
    "$ROOT_DIR/battmon_common.sh"
if /bin/bash -n "$CASE_HOME/.battmon/battery_config.sh" && \
    env HOME="$CASE_HOME" /bin/bash -c 'source "$1"' _ "$CASE_HOME/.battmon/battery_config.sh" && \
    [ ! -e "$CASE_HOME/should-not-exist" ]; then
    pass "config serialization escapes executable shell text"
else
    fail "config serialization escapes executable shell text"
fi

# Optimistic concurrency rejects stale writes.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:original"
env HOME="$CASE_HOME" BATTMON_RUNTIME_DIR="$CASE_HOME/.battmon" \
    BATTMON_CONFIG_FILE="$CASE_HOME/.battmon/battery_config.sh" \
    /bin/bash -c 'source "$1"; load_config || exit; printf "# external edit\n" >> "$BATTMON_CONFIG_FILE"; REPEAT_COUNT=2; if save_config >/dev/null 2>&1; then exit 1; fi; grep -q "external edit" "$BATTMON_CONFIG_FILE"' _ \
    "$ROOT_DIR/battmon_common.sh"
if [ "$?" -eq 0 ]; then
    pass "stale manager cannot overwrite a newer config"
else
    fail "stale manager cannot overwrite a newer config"
fi

# Read-only commands do not create runtime state.
new_case
rmdir "$CASE_HOME/.battmon"
env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/battmon" --help >/dev/null
if [ ! -e "$CASE_HOME/.battmon" ]; then
    pass "help command is read-only"
else
    fail "help command is read-only"
fi
if env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/battmon" unknown-command >/dev/null 2>&1; then
    fail "unknown command returns failure"
else
    pass "unknown command returns failure"
fi

# Stopping Battmon also clears a dead monitor lock that would block media tests.
new_case
mkdir -p "$CASE_HOME/.battmon/monitor.lock"
printf '999999\n' > "$CASE_HOME/.battmon/monitor.lock/pid"
stop_output=$(env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" \
    "$ROOT_DIR/battmon" stop 2>&1)
if [ ! -e "$CASE_HOME/.battmon/monitor.lock" ] && \
    [[ "$stop_output" == *"Background monitor is already stopped."* ]]; then
    pass "stop command removes a stale monitor lock"
else
    fail "stop command removes a stale monitor lock"
fi

# Every main-menu render clears both the visible display and scrollback.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
menu_output=$(printf '12\n11\n' | env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" \
    TERM=dumb TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false \
    TEST_CLEAR_LOG="$CASE_HOME/clear.log" TERM_PROGRAM=iTerm.app \
    "$ROOT_DIR/battmon" 2>&1)
clear_sequence=$'\033[H\033[2J\033[3J\033[H'
iterm_clear_sequence=$'\033]1337;ClearScrollback\a'
clear_count=0
iterm_clear_count=0
menu_remainder="$menu_output"
while [[ "$menu_remainder" == *"$clear_sequence"* ]]; do
    menu_remainder="${menu_remainder#*"$clear_sequence"}"
    clear_count=$((clear_count + 1))
done
menu_remainder="$menu_output"
while [[ "$menu_remainder" == *"$iterm_clear_sequence"* ]]; do
    menu_remainder="${menu_remainder#*"$iterm_clear_sequence"}"
    iterm_clear_count=$((iterm_clear_count + 1))
done
if [ "$clear_count" -eq 2 ]; then
    pass "main menu clears screen and scrollback on every render"
else
    fail "main menu clears screen and scrollback on every render"
fi
if [ "$(wc -l < "$CASE_HOME/clear.log" | tr -d ' ')" = "2" ]; then
    pass "main menu invokes terminal-native clear on every render"
else
    fail "main menu invokes terminal-native clear on every render"
fi
if [ "$iterm_clear_count" -eq 2 ]; then
    pass "iTerm2 receives its native clear-scrollback command on every render"
else
    fail "iTerm2 receives its native clear-scrollback command on every render"
fi

# Trigger choices use plain language and state exactly when speech stops.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
trigger_help_output=$(printf '2\n50\nc\n11\n' | env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" \
    TERM=dumb TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 \
    TEST_BATTERY_MODE=discharging TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false \
    "$ROOT_DIR/battmon" 2>&1)
if [[ "$trigger_help_output" == *"1) CHARGING ALERT"* ]] && \
    [[ "$trigger_help_output" == *"Use this while the battery is filling up."* ]] && \
    [[ "$trigger_help_output" == *"Starts at 50%. Unplug the charger to stop the voice."* ]] && \
    [[ "$trigger_help_output" == *"2) LOW-BATTERY ALERT"* ]] && \
    [[ "$trigger_help_output" == *"Use this while the battery is running down."* ]] && \
    [[ "$trigger_help_output" == *"Starts at 50%. Plug in the charger to stop the voice."* ]]; then
    pass "trigger choices explain direction and stop behavior plainly"
else
    fail "trigger choices explain direction and stop behavior plainly"
fi

write_config "$CASE_HOME/.battmon/battery_config.sh" \
    "80:HIGH:1:100:eighty percent" "10:LOW:1:100:ten percent"
status_output=$(env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" \
    TEST_POWER_SOURCE=Battery TEST_BATTERY_PERCENT=50 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false "$ROOT_DIR/battmon" status 2>&1)
if [[ "$status_output" == *"CHARGING"* ]] && [[ "$status_output" == *"LOW-BATT"* ]] && \
    [[ "$status_output" != *"  HIGH  "* ]]; then
    pass "status hides internal HIGH/LOW jargon where plain labels fit"
else
    fail "status hides internal HIGH/LOW jargon where plain labels fit"
fi

# Add and edit flows both expose the optional Until stopped mode.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
add_output=$(printf '2\n50\n2\n\n2\n\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false "$ROOT_DIR/battmon" 2>&1)
if env HOME="$CASE_HOME" /bin/bash -c 'source "$1"; for rule in "${ALERTS[@]}"; do [[ "$rule" == 50:LOW:0:100:* ]] && exit 0; done; exit 1' _ \
    "$CASE_HOME/.battmon/battery_config.sh" && \
    [[ "$add_output" == *"Until stopped — keep speaking until you stop it"* ]] && \
    [[ "$add_output" == *"Stop with Mute, Volume Down, or plug in the charger."* ]]; then
    pass "new alerts can use clear Until stopped behavior"
else
    fail "new alerts can use clear Until stopped behavior"
fi

edit_output=$(printf '1\n2\n\n\n2\n\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false "$ROOT_DIR/battmon" 2>&1)
if env HOME="$CASE_HOME" /bin/bash -c 'source "$1"; for rule in "${ALERTS[@]}"; do [[ "$rule" == 10:LOW:0:100:* ]] && exit 0; done; exit 1' _ \
    "$CASE_HOME/.battmon/battery_config.sh" && \
    [[ "$edit_output" == *"3. Repeat behavior:"* ]]; then
    pass "existing alerts can be changed to Until stopped"
else
    fail "existing alerts can be changed to Until stopped"
fi

new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" \
    "20:LOW:0:100:unlimited" "10:LOW:1:100:fixed"
timing_output=$(printf '6\n\n200\ny\n\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false "$ROOT_DIR/battmon" 2>&1)
if env HOME="$CASE_HOME" /bin/bash -c 'source "$1"; [[ "${ALERTS[*]}" == *"20:LOW:0:200:unlimited"* ]] && [[ "${ALERTS[*]}" == *"10:LOW:1:200:fixed"* ]]' _ \
    "$CASE_HOME/.battmon/battery_config.sh" && \
    [[ "$timing_output" == *"Rules set to Until stopped stayed unlimited."* ]]; then
    pass "batch timing keeps unlimited rules unlimited"
else
    fail "batch timing keeps unlimited rules unlimited"
fi

# Audio settings expose and persist the media pause/resume switch.
media_setting_output=$(printf '7\n\nn\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false "$ROOT_DIR/battmon" 2>&1)
if grep -q '^PAUSE_MEDIA=false$' "$CASE_HOME/.battmon/battery_config.sh" && \
    [[ "$media_setting_output" == *"resume only the media it paused"* ]]; then
    pass "media pause and resume setting is user-visible and persistent"
else
    fail "media pause and resume setting is user-visible and persistent"
fi

# The interactive test uses the production media pause/restore/resume path.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
media_test_output=$(printf '8\n5\n\n\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false TEST_SAY_LOG="$SAY_LOG" \
    TEST_EVENT_LOG="$EVENT_LOG" TEST_RUNNING_MEDIA_APPS=Spotify \
    TEST_SPOTIFY_STATE=playing "$ROOT_DIR/battmon" 2>&1)
event_sequence=$(tr '\n' '|' < "$EVENT_LOG")
if [[ "$media_test_output" == *"Media test complete. Original volume restored and playback resumed."* ]] && \
    [[ "$event_sequence" == 'media:pause:Spotify|say:Battmon media test. Your music will resume now.|audio:restore|media:resume:Spotify|' ]]; then
    pass "interactive media test pauses, speaks, restores volume, and resumes"
else
    fail "interactive media test pauses, speaks, restores volume, and resumes"
fi

# Browser permission failures explain the exact recovery step.
new_case
write_config "$CASE_HOME/.battmon/battery_config.sh" "10:LOW:1:100:ten percent"
browser_help_output=$(printf '8\n5\n\n\n11\n' | env HOME="$CASE_HOME" \
    PATH="$TEST_BIN:$ORIGINAL_PATH" TERM=dumb TEST_POWER_SOURCE=Battery \
    TEST_BATTERY_PERCENT=60 TEST_BATTERY_MODE=discharging \
    TEST_AUDIO_VOLUME=80 TEST_AUDIO_MUTED=false TEST_SAY_LOG="$SAY_LOG" \
    TEST_EVENT_LOG="$EVENT_LOG" TEST_RUNNING_MEDIA_APPS='Google Chrome' \
    TEST_CHROME_CONTROL_FAIL=1 "$ROOT_DIR/battmon" 2>&1)
if [[ "$browser_help_output" == *"Battmon could not inspect media in: Google Chrome"* ]] && \
    [[ "$browser_help_output" == *"View > Developer > Allow JavaScript from Apple Events"* ]] && \
    [ ! -s "$SAY_LOG" ]; then
    pass "media test gives actionable browser permission recovery"
else
    fail "media test gives actionable browser permission recovery"
fi

# Installer can deploy without starting or creating legacy aliases.
new_case
if env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/setup.sh" --no-start >/dev/null; then
    if [ -L "$CASE_HOME/.local/bin/battmon" ] && \
        [ ! -e "$CASE_HOME/.local/bin/battery" ] && \
        [ ! -e "$CASE_HOME/Library/LaunchAgents/com.battery.batmon.plist" ] && \
        [ "$(stat -f '%Lp' "$CASE_HOME/.battmon/battery_config.sh")" = "600" ]; then
        pass "safe no-start installation"
    else
        fail "safe no-start installation"
    fi
else
    fail "safe no-start installation"
fi

if env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/setup.sh" --no-start >/dev/null && \
    env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/setup.sh" --no-start >/dev/null; then
    backup_files=("$CASE_HOME/.battmon/backups"/battery_config.sh.*)
    if [ "${#backup_files[@]}" -eq 2 ] && [ -f "${backup_files[0]}" ] && [ -f "${backup_files[1]}" ]; then
        pass "reinstallation creates unique config backups"
    else
        fail "reinstallation creates unique config backups"
    fi
else
    fail "reinstallation creates unique config backups"
fi

if env HOME="$CASE_HOME" PATH="$TEST_BIN:$ORIGINAL_PATH" "$ROOT_DIR/setup.sh" --purge >/dev/null 2>&1; then
    fail "purge requires explicit uninstall"
else
    pass "purge requires explicit uninstall"
fi

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
