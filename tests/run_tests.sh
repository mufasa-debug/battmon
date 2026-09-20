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
    : > "$SAY_LOG"
}

write_config() {
    local path="$1"
    shift
    {
        printf 'REPEAT_COUNT=1\n'
        printf 'REPEAT_DELAY_MS=100\n'
        printf 'CHECK_INTERVAL_MS=50\n'
        printf 'ALERT_VOLUME=60\n'
        printf 'RESTORE_VOLUME=true\n'
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
        TEST_POWER_SOURCE="${TEST_POWER_SOURCE:-Battery}" \
        TEST_BATTERY_PERCENT="${TEST_BATTERY_PERCENT:-50}" \
        TEST_BATTERY_MODE="${TEST_BATTERY_MODE:-discharging}" \
        TEST_NO_BATTERY="${TEST_NO_BATTERY:-0}" \
        TEST_AUDIO_FAIL="${TEST_AUDIO_FAIL:-0}" \
        TEST_AUDIO_VOLUME=80 \
        TEST_AUDIO_MUTED=false \
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
