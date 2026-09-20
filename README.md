# Battmon

Battmon is a macOS battery voice-alert service with an 80×24 terminal manager. It watches charging and discharging thresholds, speaks configured messages, and can be interrupted immediately with a charger transition, Mute, or Volume Down. An alert can use a fixed repeat count or keep speaking until you interrupt it.

When enabled, Battmon safely pauses playing audio in Apple Music, Spotify, and QuickTime Player, plus HTML audio/video in Chrome, Brave, Safari, Edge, Vivaldi, and Chromium. After the alert, it restores the original system volume and mute state, then resumes only the players and page elements that Battmon successfully paused. Already-paused or closed media stays untouched.

Each main-menu refresh uses the terminal's native clear behavior followed by an ANSI fallback, so prior command and submenu output does not remain visible above the dashboard. In iTerm2, Battmon also sends iTerm2's native `ClearScrollback` command.

## Install

```bash
chmod +x setup.sh battmon battery_monitor.sh
./setup.sh
```

To install without starting background monitoring:

```bash
./setup.sh --no-start
```

Battmon uses only built-in macOS tools. The installer does not download packages or overwrite unrelated commands.

## Commands

```text
battmon              Interactive terminal manager
battmon status       Battery, power state, service, volume, and rules
battmon doctor       Read-only health checks
battmon run          One immediate evaluation cycle
battmon start        Install/load the LaunchAgent
battmon stop         Stop the LaunchAgent
battmon restart      Reinstall and reload the LaunchAgent
battmon test         Interactive voice/cutoff tests
battmon edit         Edit the active configuration
battmon migrate      Validate and normalize the active configuration
```

## Configuration

- Active config: `~/.battmon/battery_config.sh`
- Package/default config: `battery_config.sh` in this folder
- State: `~/.battmon/state`
- Logs: `~/Library/Logs/Battmon/battmon.log`
- LaunchAgent: `~/Library/LaunchAgents/com.battery.batmon.plist`

The active config is the single writable source of truth. The package config is never silently overwritten. Writes are atomic and reject stale edits from another open manager.

Alert format:

```text
PERCENT:TYPE:REPEATS:PAUSE_MS:MESSAGE
```

The default pause is **100 ms**. Values from **50 ms through 60,000 ms** are accepted. A repeat value of `0` means **Until stopped**; fixed repeat values are `1` through `100`.

`PAUSE_MEDIA=true` enables pause/speak/restore/resume behavior and can be changed in the interactive **Audio & media settings** screen. For Chrome or Brave, enable **View → Developer → Allow JavaScript from Apple Events**. For Safari, enable **Develop → Allow JavaScript from Apple Events**. Battmon deliberately does not send a blind global Play/Pause key, so unsupported applications are not accidentally started or resumed.

`STARTUP_GRACE_SECONDS=300` keeps Battmon silent for the first five minutes after a cold boot. Battmon also suppresses alerts for the entire time the macOS session is locked, then records the current battery state as a quiet baseline when the session becomes active. This prevents a 1% alert from speaking while a powered-off Mac is first connected to a charger or before the owner unlocks it.

## Power behavior

- **Charging alert** (stored as `HIGH`): speaks when the battery goes up to the chosen percentage. The voice stops when charging stops or the charger is unplugged.
- **Low-battery alert** (stored as `LOW`): speaks when the battery goes down to the chosen percentage. The voice stops when charging starts.
- Percentages below **30%** are always low-battery alerts. Battmon skips the type question and clearly states that plugging in the charger stops the voice.
- Low-battery alerts use the battery's real direction, including the unusual case where an adapter is attached but the battery is still going down.
- If several thresholds are crossed between checks, Battmon selects the most relevant critical threshold instead of losing all of them.
- Duplicate percentage/type messages are merged deterministically so no phrase silently becomes unreachable.
- **Until stopped** alerts repeat until Mute, Volume Down, or the appropriate charger action is detected. While speech is active, Battmon checks both `pmset` and the battery hardware's direct adapter signal so plugging or unplugging can stop the current sentence without waiting for a stale power-source report to refresh.

The interactive **Test voice & silencing keys** screen includes a media test. Start playback in a supported player or browser tab and choose the test; Battmon pauses it, speaks once, restores the original system volume and mute state, and resumes exactly what it paused. If macOS shows an Automation permission prompt the first time, choose **Allow**. If a playing native app is detected but cannot be controlled, open **System Settings → Privacy & Security → Automation** and allow the terminal app running Battmon (for example, iTerm2) to control that player.

## Safe uninstall

```bash
./setup.sh --uninstall
```

Configuration is preserved by default. To remove state and configuration too—after creating a backup—use:

```bash
./setup.sh --uninstall --purge
```

## Tests

The deterministic test suite never speaks or changes system volume:

```bash
./tests/run_tests.sh
```
