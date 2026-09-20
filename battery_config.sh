#!/bin/bash
# ==============================================================================
# Battmon Configuration File
# ------------------------------------------------------------------------------
# Edit directly or use the interactive Battmon GUI (`battmon`).
# ==============================================================================

REPEAT_COUNT=20
REPEAT_DELAY_MS=100
CHECK_INTERVAL_MS=200

ALERT_VOLUME=60
RESTORE_VOLUME=true

ALERTS=(
    "100:HIGH:20:100:Battery is fully charged"
    "80:HIGH:20:100:The battery is optimally charged"
    "39:LOW:20:100:Battery is at 39 percent"
    "15:LOW:20:100:Battery is at 15 percent"
    "13:LOW:20:50:Battery is at 13 percent"
    "10:LOW:20:100:Battery is at 10 percent"
    "10:LOW:20:100:Charge up your battery"
    "6:LOW:15:100:Battery is at 6 percent"
    "5:LOW:20:100:Battery is critically low"
    "1:LOW:20:100:Battery is critically low"
)
