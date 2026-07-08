#!/usr/bin/env bash
# Fixes thinkfan to track Package + all 4 cores (was indices:[1] = Core 0 only,
# blind to the other 3 cores). Top tier CAPPED at level 7 (~4000-4500 RPM):
# the old uncapped "disengaged" tier (>84C, ~5500 RPM) was too loud during
# sustained/AVX load. Trade: a few C hotter at the wall / slightly more throttle,
# in exchange for a much quieter machine (repaste will drop temps out of this
# tier for most loads anyway). Run with: sudo bash ./update-thinkfan.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

CONF=/etc/thinkfan.yaml
BACKUP=/etc/thinkfan.yaml.bak.$(date +%Y%m%d%H%M%S)

cp "$CONF" "$BACKUP"
echo "Backed up existing config to $BACKUP"

cat > "$CONF" <<'EOF'
# hwmon points at the /sys/class/hwmon SEARCH DIR + name: coretemp, NOT a
# hardcoded hwmonN path -- the hwmonN number is reassigned across boots (it was
# hwmon8, is now hwmon9), which silently broke thinkfan and dropped it to
# firmware auto. Name-based lookup survives the renumbering.
sensors:
  - hwmon: /sys/class/hwmon
    name: coretemp
    indices: [1, 2, 3, 4, 5]

fans:
  - tpacpi: /proc/acpi/ibm/fan

levels:
  - speed: 0
    lower_limit: [0, 0, 0, 0, 0]
    upper_limit: [42, 42, 42, 42, 42]
  - speed: 2
    lower_limit: [40, 40, 40, 40, 40]
    upper_limit: [52, 52, 52, 52, 52]
  - speed: 3
    lower_limit: [50, 50, 50, 50, 50]
    upper_limit: [60, 60, 60, 60, 60]
  - speed: 4
    lower_limit: [58, 58, 58, 58, 58]
    upper_limit: [67, 67, 67, 67, 67]
  - speed: 5
    lower_limit: [65, 65, 65, 65, 65]
    upper_limit: [73, 73, 73, 73, 73]
  - speed: 6
    lower_limit: [71, 71, 71, 71, 71]
    upper_limit: [79, 79, 79, 79, 79]
  - speed: 7
    lower_limit: [77, 77, 77, 77, 77]
    upper_limit: [32767, 32767, 32767, 32767, 32767]
EOF

echo "== Restarting thinkfan =="
systemctl restart thinkfan

sleep 1
echo "== Status =="
systemctl status thinkfan --no-pager -l
echo
echo "== Current fan level =="
cat /proc/acpi/ibm/fan
