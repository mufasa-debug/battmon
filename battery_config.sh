#!/bin/bash
# ==============================================================================
# Battmon Configuration File
# ------------------------------------------------------------------------------
# Edit directly or use the interactive Battmon GUI (`battmon`).
# ==============================================================================

REPEAT_COUNT=20
REPEAT_DELAY_MS=100
CHECK_INTERVAL_MS=200
# Stay silent while macOS is locked and for five minutes after a cold boot.
STARTUP_GRACE_SECONDS=300

ALERT_VOLUME=60
RESTORE_VOLUME=true
# Pause supported playing media, speak, restore audio, then resume it.
PAUSE_MEDIA=true

# Rule format: LEVEL:TYPE:REPEATS:PAUSE_MS:MESSAGE
# Set a rule's REPEATS field to 0 for "Until stopped" mode.
ALERTS=(
    "100:HIGH:20:100:Battery is fully charged"
    "80:HIGH:20:100:The battery is optimally charged"
    "15:LOW:20:100:Battery is at 15 percent"
    "5:LOW:20:100:Battery is critically low"
    "1:LOW:20:100:Battery is critically low"
)

# Optional local-time ranges during which alerts should stay silent.
# Use 24-hour HH:MM-HH:MM format; an empty list disables quiet times.
ALERT_TIMES=()
