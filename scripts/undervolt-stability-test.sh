#!/usr/bin/env bash
# ============================================================================
# WARNING: DO NOT AGGRESSIVELY UNDERVOLT. If you see ANY freeze, crash, or
# hardware error at any step, STOP immediately -- revert to stock (0 mV) or
# your last confirmed-stable value. Do not push deeper "to see how far it goes."
# ============================================================================
# Incremental core/cache undervolt stability test.
# Run with: sudo bash ./undervolt-stability-test.sh
#
# If the system crashes/reboots mid-test, check the log
# ($REAL_HOME/undervolt-stability-test.log) -- the last step logged as
# "completed cleanly" is the last confirmed-stable offset. Whatever step
# was running when it crashed is NOT stable; back off from there.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

UNDERVOLT=$REAL_HOME/.local/bin/undervolt
LOG=$REAL_HOME/undervolt-stability-test.log
OFFSETS=(-60 -75 -90)
LOAD_SECONDS=30
NCPU=$(nproc)

echo "=== Undervolt stability test started: $(date) ===" | tee -a "$LOG"

for OFFSET in "${OFFSETS[@]}"; do
    echo "--- Testing core/cache offset: ${OFFSET} mV ---" | tee -a "$LOG"

    "$UNDERVOLT" --core "$OFFSET" --cache "$OFFSET" 2>&1 | tee -a "$LOG"

    echo "Applying all-core load for ${LOAD_SECONDS}s..." | tee -a "$LOG"
    PIDS=()
    for i in $(seq 1 "$NCPU"); do
        yes > /dev/null &
        PIDS+=($!)
    done

    sleep "$LOAD_SECONDS"

    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null

    NEW_ERRORS=$(dmesg 2>/dev/null | grep -iE "mce|machine check|whea|hardware error" | tail -20)
    if [ -n "$NEW_ERRORS" ]; then
        echo "!!! Hardware error events detected at ${OFFSET} mV -- STOPPING here." | tee -a "$LOG"
        echo "$NEW_ERRORS" | tee -a "$LOG"
        echo "Last confirmed stable offset was the previous step in this log." | tee -a "$LOG"
        exit 1
    fi

    TEMP=$(sensors 2>/dev/null | grep -m1 "Package id 0" | grep -oE '[+-][0-9]+\.[0-9]+°C')
    echo "Step ${OFFSET} mV completed cleanly. Package temp at end: ${TEMP}" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
done

echo "=== All offsets tested successfully. Deepest tested: ${OFFSETS[-1]} mV ===" | tee -a "$LOG"
echo "Reminder: back off ~10mV from the deepest stable value before making it permanent." | tee -a "$LOG"
