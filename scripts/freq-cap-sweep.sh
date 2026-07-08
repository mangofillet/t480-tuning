#!/usr/bin/env bash
# Sweeps intel_pstate max_perf_pct to find the cap that lands sustained
# all-core load around ~80C. Run with: sudo bash ./freq-cap-sweep.sh
#
# Do not Ctrl+Z this script -- that suspends it without running cleanup,
# leaving max_perf_pct stuck and yes processes stopped-but-not-killed. If you
# need to abort, use Ctrl+C: the trap below still restores the original value.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

MAXPCT=/sys/devices/system/cpu/intel_pstate/max_perf_pct
LOG=$REAL_HOME/freq-cap-sweep.log
# Re-baseline after any undervolt change -- heat-per-clock shifts, so the cap
# that lands your target temp shifts too. On this author's chip, with -100mV
# core/cache/gpu already live, 82 down through 72 ALL still pinned at the
# 96-97C PROCHOT wall -- only 70 actually moved the needle (89C). Don't assume
# a result here transfers to a different undervolt depth; always re-sweep.
CANDIDATES=(82 80 78 76 74 72 70)
# 90s = reach thermal steady state (30s under-reads the true sustained ceiling).
LOAD_SECONDS=90
COOLDOWN_SECONDS=60
NCPU=$(nproc)
# Worst-case thermal load: AVX/matrix via stress-ng if available, else plain `yes`
# (integer-only, runs cooler -> would under-report the ceiling).
if command -v stress-ng >/dev/null 2>&1; then
    LOADER=stress-ng
else
    LOADER=yes
    echo "NOTE: stress-ng not found -- falling back to 'yes' (lighter, cooler load)." >&2
fi
ORIG=$(cat "$MAXPCT")

cleanup() {
    echo "$ORIG" > "$MAXPCT" 2>/dev/null
    echo "=== Restored max_perf_pct to ${ORIG} (cleanup trap) ===" | tee -a "$LOG"
}
trap cleanup EXIT INT TERM

get_temp() {
    sensors 2>/dev/null | awk -F'[+°]' '/Package id 0/{print $2; exit}'
}

echo "=== Frequency cap sweep started: $(date) ===" | tee -a "$LOG"
echo "Original max_perf_pct: $ORIG" | tee -a "$LOG"

echo "Waiting for baseline temp to settle before starting..." | tee -a "$LOG"
for i in $(seq 1 12); do
    t=$(get_temp)
    echo "  settle check: ${t}C" | tee -a "$LOG"
    awk -v t="$t" 'BEGIN{exit !(t < 55)}' && break
    sleep 10
done

for PCT in "${CANDIDATES[@]}"; do
    echo "--- Testing max_perf_pct=${PCT} ---" | tee -a "$LOG"
    echo "$PCT" > "$MAXPCT"

    PIDS=()
    if [[ "$LOADER" == stress-ng ]]; then
        stress-ng --cpu "$NCPU" --cpu-method matrixprod --timeout $((LOAD_SECONDS + 5))s >/dev/null 2>&1 &
        PIDS+=($!)
    else
        for i in $(seq 1 "$NCPU"); do
            yes > /dev/null &
            PIDS+=($!)
        done
    fi

    sleep "$LOAD_SECONDS"

    avgfreq=$(awk '{sum+=$1; n++} END {printf "%.0f", sum/n/1000}' <(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq))
    pkgtemp=$(get_temp)

    for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
    pkill -9 -x stress-ng 2>/dev/null
    wait 2>/dev/null

    echo "max_perf_pct=${PCT}  ->  AvgMHz=${avgfreq}  PkgTemp=${pkgtemp}C" | tee -a "$LOG"

    echo "Cooling down for ${COOLDOWN_SECONDS}s before next step..." | tee -a "$LOG"
    sleep "$COOLDOWN_SECONDS"
    echo "  post-cooldown temp: $(get_temp)C" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
done

echo "=== Sweep complete. ===" | tee -a "$LOG"
