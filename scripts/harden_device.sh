#!/usr/bin/env bash
# One-time device hardening for offline forks.
# Run ON THE DEVICE (via adb/SSH): ./scripts/harden_device.sh [--disable-ssh] [--wipe-identity]
#
# - backs up and clears /home/comma/.ssh/authorized_keys (removes comma support keys)
# - removes the GithubSshKeys param so nothing re-injects keys at boot
# - masks systemd-timesyncd (time comes from GPS via timed)
# - --disable-ssh additionally turns off sshd entirely
# - --wipe-identity removes all identifiers and history before selling/sharing hardware:
#     params (DongleId etc.), /persist/comma keys, driving logs, swaglogs, crash dumps
set -euo pipefail

DISABLE_SSH=0
WIPE=0
for arg in "$@"; do
  case "$arg" in
    --disable-ssh) DISABLE_SSH=1 ;;
    --wipe-identity) WIPE=1 ;;
    *) echo "usage: $0 [--disable-ssh] [--wipe-identity]" >&2; exit 1 ;;
  esac
done

AK=/home/comma/.ssh/authorized_keys
if sudo test -f "$AK"; then
  BAK="$AK.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp "$AK" "$BAK"
  sudo truncate -s 0 "$AK"
  sudo chown comma:comma "$AK" "$BAK" 2>/dev/null || true
  echo "cleared $AK (backup: $BAK)"
else
  echo "no authorized_keys found at $AK"
fi

for p in /data/params/d/GithubSshKeys /data/params/d/GithubUsername; do
  sudo rm -f "$p"
done
echo "removed SSH key params"

sudo systemctl mask --now systemd-timesyncd.service
echo "systemd-timesyncd masked"

if [ "$DISABLE_SSH" -eq 1 ]; then
  sudo systemctl disable --now ssh sshd 2>/dev/null || true
  sudo systemctl mask ssh sshd 2>/dev/null || true
  echo "sshd disabled and masked"
else
  echo "sshd left enabled; rerun with --disable-ssh to turn it off"
fi

if [ "$WIPE" -eq 1 ]; then
  echo "wiping identity and history (openpilot must not be running)"
  for key in DongleId GithubSshKeys GithubUsername HardwareSerial PrimeType; do
    sudo rm -f "/data/params/d/$key"
  done
  sudo rm -rf /persist/comma
  sudo rm -rf /data/media/0/realdata
  sudo rm -rf /data/log
  sudo rm -rf /data/tombstones
  sudo rm -rf /var/crash
  echo "identity wiped; device re-registers fresh on next boot"
fi

echo "done. reboot to apply."
