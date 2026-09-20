# Battmon Technical Reference

Battmon is a macOS LaunchAgent and terminal manager. The implementation targets the system Bash 3.2 runtime and built-in macOS commands only.

## Architecture

```mermaid
flowchart TD
    CLI["battmon TUI and CLI"] --> COMMON["battmon_common.sh"]
    MONITOR["battery_monitor.sh"] --> COMMON
    CLI --> CONFIG["~/.battmon/battery_config.sh"]
    MONITOR --> CONFIG
    LAUNCHD["com.battery.batmon LaunchAgent"] --> MONITOR
    MONITOR --> STATE["~/.battmon/state"]
    MONITOR --> LOG["~/Library/Logs/Battmon/battmon.log"]
    COMMON --> PMSET["pmset battery state"]
    COMMON --> AUDIO["osascript volume and mute"]
    MONITOR --> SAY["say speech process"]
    MONITOR --> MEDIA["Native players and browser media"]
```

### Files

- `battmon`: interactive manager, service controls, diagnostics, and config editing.
- `battery_monitor.sh`: one evaluation cycle plus interruptible speech.
- `battmon_common.sh`: shared config, battery, audio, formatting, and logging functions.
- `battery_config.sh`: portable seed/default configuration. It is not a live mirror.
- `setup.sh`: safe install, migration, service registration, and uninstall.
- `com.battery.batmon.plist`: distribution template; setup generates the user-specific plist.
- `tests/`: deterministic command stubs and regression tests.

## Configuration ownership

`~/.battmon/battery_config.sh` is the only writable source of truth. The Desktop/package copy is a seed for a first install and is never silently synchronized back from the active config.

The manager records a checksum when loading the config. Before saving, it takes a lock and compares the current checksum with the loaded checksum. If another manager wrote a newer version, the stale save is rejected. Writes use a temporary file in the runtime directory followed by an atomic rename.

Generated alert values use Bash `%q` escaping, so quotes, command substitutions, backticks, spaces, and backslashes remain literal message text.

```text
LEVEL:TYPE:REPEAT_COUNT:PAUSE_DELAY_MS:MESSAGE
```

- Level: 1–100
- Type: `LOW` or `HIGH`
- Repeats: 1–100 for fixed mode; `0` means repeat until interrupted
- Pause: 50–60,000 ms; default 100 ms
- Message: non-empty text; `{percent}`, `{level}`, and `{pct}` interpolate live battery percentage

Invalid numeric fields and malformed rules are rejected or replaced by safe defaults. Duplicate level/type rules are normalized into one ordered combined message, preventing unreachable duplicate rules.

## Battery model

Battery source and battery activity are deliberately separate:

- Source: `AC`, `BATTERY`, or `UNKNOWN`
- Mode: `charging`, `charged`, `discharging`, or `unknown`

This matters because macOS can report AC power while the battery is still discharging. `LOW` rules use actual discharging mode. `HIGH` rules use charging/charged mode. The TUI reports this state explicitly instead of calling every AC-powered state “charging.”

Trigger selection supports:

1. Exact threshold arrival.
2. Inclusive threshold crossing between LaunchAgent runs.
3. A transition into charging or discharging while already beyond a threshold.
4. Large jumps across several thresholds. LOW selects the lowest crossed configured threshold; HIGH selects the highest crossed threshold.

Only the selected rule is announced. State is persisted before speech begins so overlapping manual/LaunchAgent checks cannot repeat the same alert.

## Locked-session and cold-boot suppression

Before selecting a rule, the monitor checks the current GUI session through `ioreg`. Its potentially large output is reduced directly by `awk`; the full response is never copied and rewritten inside Bash. While `CGSSessionScreenIsLocked` is true, no alert is spoken. It also reads `kern.boottime` through `sysctl` and stays silent for `STARTUP_GRACE_SECONDS` (default 300 seconds) after a cold boot.

Suppression is persisted in `LAST_SESSION_BLOCKED`. On the first active check after the lock or startup quiet period ends, Battmon records the current percentage, power direction, and any exact matching rule as a silent baseline. This prevents the same 1% rule from firing one minute after unlock while allowing it to re-arm normally after the battery leaves that percentage.

## State and locks

State is atomically stored in `~/.battmon/state`:

```text
LAST_PERCENT=13
LAST_ALERT_LEVEL=13
LAST_ALERT_TYPE=LOW
LAST_MODE=discharging
LAST_SOURCE=BATTERY
LAST_SESSION_BLOCKED=0
```

The monitor lock and configuration lock live under the owner-only `~/.battmon` directory. Stale locks are reclaimed only when their recorded process is no longer the corresponding Battmon process.

## Interruptible speech

Speech runs asynchronously. While `say` is active, the monitor polls battery and audio state at `CHECK_INTERVAL_MS` (default 200 ms). Pause polling uses the smaller of the configured pause and check interval, so a 50 ms pause stays interruptible without rounding to zero.

Cutoffs include:

- Charger source transition during an alert.
- Battery changing from discharging to charging/charged.
- HIGH alert losing AC or beginning to discharge.
- Hardware Mute.
- Any deliberate Volume Down change below the active alert volume.
- `INT`, `TERM`, or `HUP` signals.

Signal handlers exit with conventional status codes. The EXIT cleanup stops the speech child, restores audio unless the user deliberately changed it, and releases the monitor lock.

For an unlimited rule (`REPEAT_COUNT=0`), the same loop continues without a numeric limit. The charger, Mute, Volume Down, and signal checks remain active during speech and between repetitions.

### Media pause and restoration

`PAUSE_MEDIA=true` enables explicit control of Apple Music, Spotify, the front playing document in QuickTime Player, and HTML audio/video in Chrome, Brave, Safari, Edge, Vivaldi, and Chromium. Before speech, the monitor:

1. Uses `pgrep -x` so an inactive application is never launched just to inspect it.
2. Asks each running application whether it is currently playing.
3. Pauses it and records it only when the pause command succeeds.
4. Snapshots and prepares system audio, then speaks the alert.

For browsers, a short script scans ordinary web tabs and marks only media elements that are actively playing before pausing them. Cleanup searches for that private marker, removes it, and resumes those elements without changing their page volume or current playback position.

Cleanup stops speech, restores the original volume and mute state, and only then resumes the recorded players. A player that was paused beforehand is never resumed, and an application closed during the alert is not relaunched. If media was paused, the original audio state is restored even when Volume Down or Mute caused the interruption; otherwise, a deliberate user audio change is preserved as before.

Battmon does not synthesize a global media key. That would require Accessibility permission, could control the wrong application, and could resume media Battmon did not pause. Unsupported applications are therefore left unchanged. Chromium browsers and Safari must allow JavaScript from Apple Events; the interactive test prints the exact menu path when this permission is missing.

The TUI media test invokes the same production `--test-media` path as real alerts. It takes the monitor lock, verifies supported media is actively playing, pauses it, speaks one test sentence, restores audio, and resumes only the recorded media. Native-player Apple event failures are reported separately from a genuine no-media result, including the terminal-specific macOS Automation recovery path. Native-player Apple events have a two-second timeout and browser scans have a five-second timeout, so a stuck application cannot indefinitely block an alert or cleanup. `battmon stop` also clears dead monitor locks and safely asks a live monitor to terminate.

If the original audio state cannot be read, Battmon speaks without changing volume. It never invents a fallback volume that could later overwrite the user's real setting.

## Installation lifecycle

`setup.sh` performs these steps:

1. Verify macOS and required built-in commands, including `ioreg`, `sysctl`, and `pgrep`.
2. Syntax-check every installed shell file.
3. Refuse to overwrite an unrelated `~/.local/bin/battmon` command.
4. Back up the active configuration.
5. Atomically deploy the CLI, engine, and common library.
6. Migrate/normalize the active config.
7. Remove only legacy aliases that still point to Battmon.
8. Generate and validate the LaunchAgent.
9. Load and verify the service, unless `--no-start` was requested.

The installer never calls Homebrew and never changes shell startup files. Uninstall removes only verified Battmon-owned command links. Configuration is preserved unless `--purge` is explicitly supplied, and purge first creates a backup.

## Logs and diagnostics

Logs are private to the user under `~/Library/Logs/Battmon`. At 1 MiB, the current log is rotated to `battmon.log.1`.

`battmon doctor` is read-only and checks:

- Platform and built-in commands
- Configuration syntax and normalization
- Battery parsing
- Audio-state access
- LaunchAgent plist validity
- Current service status

`battmon --help`, `battmon status`, and `battmon doctor` do not create or synchronize configuration files.

## Tests

Run:

```bash
./tests/run_tests.sh
```

The suite prepends deterministic stubs for `pmset`, `osascript`, `pgrep`, `ioreg`, `sysctl`, `say`, `sleep`, and `launchctl`. It does not speak, change volume, control real media, or load a real service. Covered workflows include exact triggers, debounce, large lock-state responses, locked-session and cold-boot suppression, post-unlock re-arming, stale monitor-lock recovery, multi-threshold jumps, AC-attached discharging, charging suppression, unlimited-repeat interruption, native and browser media pause/restore/resume, browser permission guidance, the interactive media test, already-paused media safety, disabled media control, duplicate normalization, shell-safe messages, stale-manager collision rejection, read-only help, unknown commands, and no-start installation.
