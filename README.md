# Battmon

Battmon is a macOS battery voice-alert service with an 80×24 terminal manager. It watches charging and discharging thresholds, speaks configured messages, and can be interrupted immediately with a charger transition, Mute, or Volume Down.

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

The default pause is **100 ms**. Values from **50 ms through 60,000 ms** are accepted.

## Power behavior

- **Charging alert** (stored as `HIGH`): speaks when the battery goes up to the chosen percentage. The voice stops when charging stops or the charger is unplugged.
- **Low-battery alert** (stored as `LOW`): speaks when the battery goes down to the chosen percentage. The voice stops when charging starts.
- Low-battery alerts use the battery's real direction, including the unusual case where an adapter is attached but the battery is still going down.
- If several thresholds are crossed between checks, Battmon selects the most relevant critical threshold instead of losing all of them.
- Duplicate percentage/type messages are merged deterministically so no phrase silently becomes unreachable.

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
