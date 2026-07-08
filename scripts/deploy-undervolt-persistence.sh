#!/usr/bin/env bash
# Installs boot + resume-from-suspend persistence for the T480 core/cache undervolt.
# Run with: sudo bash ./deploy-undervolt-persistence.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

UNDERVOLT=$REAL_HOME/.local/bin/undervolt
# --core/--cache/--gpu: -100 mV on this author's chip. THIS IS NOT A SAFE
#      DEFAULT FOR YOUR CHIP -- silicon lottery is real (this unit walled out
#      at -150mV in a short sweep; -100 has NOT been through a multi-day
#      real-world soak test, only a short synthetic stress pass -- see the
#      README's "IMPORTANT LESSON" before trusting anything beyond a value
#      YOU have soak-tested yourself). -80 mV was this chip's long-run,
#      soak-validated-safe value. Find your own number with
#      undervolt-deep-sweep.sh before editing OFFSETS below.
# -p1: PL1 (sustained) set to 25W -- the i7-8550U's Intel-rated cTDP-up ceiling,
#      not the 15W base TDP. Goal is raising safe sustained clocks, spending the
#      undervolt's heat-per-clock savings on performance rather than lower temps.
#      (Prior BIOS default of 200W wasn't a real limit -- thermal was governing
#      instead, causing throttling; 25W is a real, chip-rated sustained cap.)
# -t:  DROPPED -- this chip's microcode rejects writes to IA32_TEMPERATURE_TARGET
#      (OSError: Input/output error, i.e. a real #GP fault, not a permissions/
#      lockdown issue). Confirmed the crash happens before -p1/--turbo run, since
#      undervolt.py applies core/cache -> temp -> power-limit -> turbo in that
#      order, so leaving -t in aborts the whole service every time. PL1 cap below
#      is the actual anti-throttle lever anyway; stock 97C threshold is the
#      unavoidable fallback.
# --gpu: iGPU (UHD 620) voltage plane, tracked alongside core/cache.
#      uncore/analogio deliberately left at 0 -- uncore undervolt risks silent
#      memory-controller data corruption (no clean crash to catch it), not worth it.
# -p2: PL2 (short-term burst) set to 40W / 3s window, up from stock 29W. On a
#      T480 this is thermally-governed -- the 97C PROCHOT reins a 40W burst in
#      within a couple seconds -- so it doesn't raise sustained power or heat, it
#      just lets short bursts ramp harder for snappier responsiveness. Harmless.
# --turbo 0: explicitly keep turbo enabled (tool's flag is inverted: 0=enable).
OFFSETS="--core -100 --cache -100 --gpu -100 -p1 25 28 -p2 40 3 --turbo 0"

echo "== Ensuring msr module loads at boot =="
echo msr > /etc/modules-load.d/msr.conf

echo "== Installing systemd service (applies offsets at boot) =="
cat > /etc/systemd/system/undervolt.service <<EOF
[Unit]
Description=Apply CPU core/cache undervolt offsets at boot
After=systemd-modules-load.service
Requires=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=$UNDERVOLT $OFFSETS
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "== Installing resume-from-suspend hook (offsets reset on wake) =="
cat > /usr/lib/systemd/system-sleep/undervolt-resume <<EOF
#!/bin/sh
case "\$1" in
    post)
        $UNDERVOLT $OFFSETS
        ;;
esac
EOF
chmod 755 /usr/lib/systemd/system-sleep/undervolt-resume

echo "== Enabling and (re)starting boot service now =="
systemctl daemon-reload
systemctl enable undervolt.service
systemctl restart undervolt.service

echo
echo "== Verifying =="
"$UNDERVOLT" -r
