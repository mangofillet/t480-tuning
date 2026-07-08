#!/usr/bin/env bash
# Deep core/cache undervolt sweep -- hunts past the -90mV already confirmed.
# Run with: sudo bash ./undervolt-deep-sweep.sh
#
# Steps core+cache together from -100 to -150 mV in -10 steps. At each rung it
# runs a real AVX/FPU/matrix stress load and checks the kernel log for NEW
# machine-check / WHEA events (timestamp-gated, so stale errors don't false-trip).
#
# CRASH RECOVERY: if the box locks up or reboots mid-test, read the log
# ($REAL_HOME/undervolt-deep-sweep.log). The last "completed cleanly" line is the
# last CONFIRMED-STABLE offset. The step running when it died is NOT stable.
# On the next boot undervolt.service re-applies the safe -80mV, so a crash is
# self-healing -- you just lose the test session, not the persistent config.
#
# ON SUCCESS/ERROR this script reverts to the safe -80mV so it never LEAVES the
# machine at an untested-deep offset. To make a new value permanent you must
# edit deploy-undervolt-persistence.sh yourself -- this script only TESTS.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

UNDERVOLT=$REAL_HOME/.local/bin/undervolt
LOG=$REAL_HOME/undervolt-deep-sweep.log
SAFE_OFFSET=-80              # known-good; restored on exit
OFFSETS=(-100 -110 -120 -130 -135 -140 -145 -150 -155 -160)  # -5 steps past -130, where the wall lives
LOAD_SECONDS=90             # longer than the 30s smoke test -- marginal UV needs time
NCPU=$(nproc)

# Pick the best available stress tool. `yes` only exercises integer ALU and will
# happily "pass" an offset that a real FPU/AVX load would crash -- that's why the
# original 30s test wasn't enough to trust deep offsets.
if command -v stress-ng >/dev/null 2>&1; then
    STRESS_KIND=stress-ng
elif command -v mprime >/dev/null 2>&1; then
    STRESS_KIND=mprime
else
    STRESS_KIND=yes
fi

restore_safe() {
    echo "--- Reverting to safe ${SAFE_OFFSET} mV ---" | tee -a "$LOG"
    "$UNDERVOLT" --core "$SAFE_OFFSET" --cache "$SAFE_OFFSET" 2>&1 | tee -a "$LOG"
}
trap restore_safe EXIT

run_stress() {
    case "$STRESS_KIND" in
        stress-ng)
            # cpu stressors cycle through FPU/int/AVX; --matrix hammers cache+FP.
            stress-ng --cpu "$NCPU" --cpu-method all \
                      --matrix "$NCPU" --matrix-size 128 \
                      --timeout "${LOAD_SECONDS}s" --metrics-brief 2>&1 | tail -3
            ;;
        *)
            PIDS=()
            for _ in $(seq 1 "$NCPU"); do yes > /dev/null & PIDS+=($!); done
            sleep "$LOAD_SECONDS"
            for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
            wait 2>/dev/null
            ;;
    esac
}

echo "=== Deep undervolt sweep started: $(date) ===" | tee -a "$LOG"
echo "Stress tool: $STRESS_KIND | load: ${LOAD_SECONDS}s | cpus: $NCPU" | tee -a "$LOG"
if [ "$STRESS_KIND" = "yes" ]; then
    echo "WARNING: neither stress-ng nor mprime installed -- falling back to 'yes'" | tee -a "$LOG"
    echo "  (integer-only; a deep offset that survives this may still fail real FP/AVX)." | tee -a "$LOG"
    echo "  Recommended: sudo apt install stress-ng, then rerun." | tee -a "$LOG"
fi

for OFFSET in "${OFFSETS[@]}"; do
    echo "" | tee -a "$LOG"
    echo "--- Testing core/cache offset: ${OFFSET} mV ---" | tee -a "$LOG"

    MARK="$(date '+%Y-%m-%d %H:%M:%S')"   # only count kernel errors AFTER this

    "$UNDERVOLT" --core "$OFFSET" --cache "$OFFSET" 2>&1 | tee -a "$LOG"

    echo "Applying stress for ${LOAD_SECONDS}s..." | tee -a "$LOG"
    run_stress | tee -a "$LOG"

    # Timestamp-gated: only NEW machine-check/WHEA lines since MARK count.
    NEW_ERRORS=$(journalctl -k --since "$MARK" 2>/dev/null \
                 | grep -iE "mce|machine check|whea|hardware error")
    if [ -n "$NEW_ERRORS" ]; then
        echo "!!! NEW hardware-error events at ${OFFSET} mV -- STOPPING." | tee -a "$LOG"
        echo "$NEW_ERRORS" | tee -a "$LOG"
        echo ">>> Last confirmed-stable = previous step. Back off ~15mV from ${OFFSET} for permanent." | tee -a "$LOG"
        exit 1   # trap restores safe -80
    fi

    TEMP=$(sensors 2>/dev/null | grep -m1 "Package id 0" | grep -oE '[+-][0-9]+\.[0-9]+°C')
    echo "Step ${OFFSET} mV completed cleanly. Package temp at end: ${TEMP}" | tee -a "$LOG"
done

echo "" | tee -a "$LOG"
echo "=== All offsets survived. Deepest tested: ${OFFSETS[-1]} mV ===" | tee -a "$LOG"
echo "Back off ~15mV from the deepest before making it permanent (deep offsets" | tee -a "$LOG"
echo "want more margin than the shallow ones -- temperature & aging shift Vmin)." | tee -a "$LOG"
# trap restores safe -80 on exit
