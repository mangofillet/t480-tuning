#!/usr/bin/env bash
# Installs boot + resume-from-suspend persistence for an intel_pstate max_perf_pct
# frequency cap. Run with: sudo bash ./deploy-freqcap-persistence.sh
#
# CORRECTED 2026-07-08: the original version of this script picked CAP=72 based
# on a misread of freq-cap-sweep.log. The actual re-baselined sweep (run
# 2026-07-08 02:31, with the -100mV core/cache/iGPU undervolt already live)
# shows 82/80/78/76/74/72% ALL still pin at 96-97C (PROCHOT wall) -- the cap
# only becomes the binding constraint at 70%, which lands 89C / ~2800MHz avg.
# None of the tested steps hit an 85C target; 70% is simply the best of what
# was actually tested. If you want closer to 85C, extend the sweep below 70%
# (65/66/68 not yet tried) before changing this value.
# Turbo stays enabled -- this only caps the sustained P-state ceiling, so short
# bursts still ramp; the cap reins in sustained heat.
# max_perf_pct can be reinitialised on resume, so a system-sleep hook re-applies.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

MAXPCT_FILE=/sys/devices/system/cpu/intel_pstate/max_perf_pct
CAP=70

if [[ ! -w "$MAXPCT_FILE" ]]; then
    echo "ERROR: $MAXPCT_FILE not writable/present (is intel_pstate active?)" >&2
    exit 1
fi

echo "== Installing systemd service (applies freq cap at boot) =="
cat > /etc/systemd/system/freqcap.service <<EOF
[Unit]
Description=Cap intel_pstate max_perf_pct to reduce sustained PROCHOT throttling
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $CAP > $MAXPCT_FILE'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "== Installing resume-from-suspend hook (cap re-applied on wake) =="
cat > /usr/lib/systemd/system-sleep/freqcap-resume <<EOF
#!/bin/sh
case "\$1" in
    post)
        echo $CAP > $MAXPCT_FILE
        ;;
esac
EOF
chmod 755 /usr/lib/systemd/system-sleep/freqcap-resume

echo "== Enabling and (re)starting boot service now =="
systemctl daemon-reload
systemctl enable freqcap.service
systemctl restart freqcap.service

echo
echo "== Verifying =="
echo "max_perf_pct now: $(cat "$MAXPCT_FILE")  (expected $CAP)"
