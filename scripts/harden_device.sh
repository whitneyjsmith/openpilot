#!/usr/bin/env bash
#
# harden_device.sh — lock down a comma device running openpilot / AGNOS.
#
# This is an offline, on-device utility. It has three independent jobs:
#
#   --disable-network   Turn off Wi-Fi and stop the device from talking to
#                       comma's cloud / API (athena, uploader).
#   --harden            Security hardening: disable SSH, remove authorized
#                       SSH keys, tighten permissions on identity files.
#   --wipe-identity     DESTRUCTIVE. Erase the device identity, saved Wi-Fi
#                       networks and recorded drives. Use this before you
#                       sell, lend, or hand off the hardware.
#
#   --all               Shortcut for: --harden --disable-network
#                       (a non-destructive lockdown; leaves identity intact)
#
# Options:
#   -n, --dry-run       Print every action; change nothing.
#   -y, --yes           Don't prompt for confirmation (use with care).
#   -h, --help          Show this help and exit.
#
# Notes:
#   * --wipe-identity is NOT a full factory reset. It removes the sensitive,
#     personal state but leaves openpilot installed. For a complete erase of
#     the data partition, use the built-in reset (system/ui/reset.py) or the
#     "Reset" option in the device settings.
#   * Everything here is reversible except --wipe-identity. Re-enabling the
#     network / SSH just means turning them back on in openpilot settings.
#
set -euo pipefail

# ----- configuration ---------------------------------------------------------
PARAMS_ROOT="${PARAMS_ROOT:-/data/params}"
PARAMS_DIR="${PARAMS_ROOT}/${OPENPILOT_PREFIX:-d}"
PERSIST_ROOT="${PERSIST_ROOT:-/persist}"
REALDATA_DIR="${REALDATA_DIR:-/data/media/0/realdata}"
NM_CONN_DIRS=(
  "/data/etc/NetworkManager/system-connections"
  "/run/NetworkManager/system-connections"
)
# Files under /persist/comma that make up the device identity.
IDENTITY_FILES=(
  "${PERSIST_ROOT}/comma/dongle_id"
  "${PERSIST_ROOT}/comma/id_rsa"
  "${PERSIST_ROOT}/comma/id_rsa.pub"
)
# Params that hold identity / cloud credentials.
IDENTITY_PARAMS=(
  DongleId HardwareSerial ApiCache_Device ApiCache_FirehoseStats
  AccessToken GithubSshKeys GithubUsername InstallDate PrimeType
  AthenadUploadQueue AthenadRecentlyViewedRoutes AthenadPid
)

# ----- ui helpers ------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""
fi
log()  { echo "${1}"; }
info() { echo "${GREEN}==>${NC} ${1}"; }
warn() { echo "${YELLOW}warning:${NC} ${1}" >&2; }
err()  { echo "${RED}error:${NC} ${1}" >&2; }
die()  { err "$1"; exit 1; }

DRY_RUN=false
ASSUME_YES=false

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Run a command, or just describe it under --dry-run.
run() {
  if $DRY_RUN; then
    log "    ${YELLOW}dry-run:${NC} $*"
  else
    "$@"
  fi
}

confirm() {
  $ASSUME_YES && return 0
  local ans
  read -r -p "${BOLD}$1${NC} [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

set_param() {
  local key="$1" val="$2"
  info "set param ${key}=${val}"
  if $DRY_RUN; then log "    ${YELLOW}dry-run:${NC} write ${PARAMS_DIR}/${key}"; return; fi
  as_root mkdir -p "$PARAMS_DIR"
  # atomic-ish write, mirroring how Params stores values (one file per key)
  local tmp; tmp="$(as_root mktemp "${PARAMS_DIR}/.tmp_harden_XXXXXX")"
  printf '%s' "$val" | as_root tee "$tmp" >/dev/null
  as_root mv -f "$tmp" "${PARAMS_DIR}/${key}"
}

del_param() {
  local key="$1"
  [[ -e "${PARAMS_DIR}/${key}" ]] || return 0
  info "remove param ${key}"
  run as_root rm -f -- "${PARAMS_DIR}/${key}"
}

del_path() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  info "remove ${p}"
  run as_root rm -rf -- "$p"
}

# ----- safety: make sure this looks like a comma device ----------------------
assert_device() {
  if [[ -n "${OP_HARDEN_FORCE:-}" ]]; then return 0; fi
  if [[ -e /AGNOS-VERSION || -d /data/params || -d "${PERSIST_ROOT}/comma" ]]; then
    return 0
  fi
  die "this does not look like a comma device (no /data/params or /persist/comma).
       Refusing to run. Set OP_HARDEN_FORCE=1 to override."
}

# ----- actions ---------------------------------------------------------------
disable_network() {
  info "${BOLD}Disabling Wi-Fi and cloud/API access${NC}"

  # 1. Turn off the Wi-Fi radio (also drops tethering).
  if have nmcli; then
    run as_root nmcli radio wifi off || warn "could not turn Wi-Fi radio off"
  else
    warn "nmcli not found; skipping Wi-Fi radio toggle"
  fi

  # 2. Discourage any metered/cellular data use.
  set_param GsmRoaming "0"
  set_param NetworkMetered "1"

  # 3. Stop the daemons that talk to comma's servers, and clear the
  #    pending upload queue so nothing is sent when a link returns.
  for proc in manage_athenad athenad uploader; do
    if pgrep -f "$proc" >/dev/null 2>&1; then
      info "stopping ${proc}"
      run as_root pkill -f "$proc" || true
    fi
  done
  del_param AthenadUploadQueue

  # 4. Mark the device hardened so it's obvious later.
  set_param DisableUpdates "1"

  info "network + cloud access disabled"
}

harden() {
  info "${BOLD}Applying security hardening${NC}"

  # 1. SSH off, and remove any authorized GitHub keys openpilot injected.
  set_param SshEnabled "0"
  del_param GithubSshKeys
  del_param GithubUsername
  if have systemctl; then
    run as_root systemctl stop ssh 2>/dev/null || true
    run as_root systemctl disable ssh 2>/dev/null || true
  fi
  if pgrep -x sshd >/dev/null 2>&1; then
    run as_root pkill -x sshd || true
  fi
  for ak in /home/comma/.ssh/authorized_keys /data/params/d/GithubSshKeys; do
    del_path "$ak"
  done

  # 2. Lock down permissions on the identity key material that remains.
  if [[ -d "${PERSIST_ROOT}/comma" ]]; then
    run as_root chmod 700 "${PERSIST_ROOT}/comma" || true
    [[ -f "${PERSIST_ROOT}/comma/id_rsa" ]] && \
      run as_root chmod 600 "${PERSIST_ROOT}/comma/id_rsa" || true
  fi

  info "security hardening applied"
}

wipe_identity() {
  info "${BOLD}WIPE IDENTITY${NC} — for selling or sharing this hardware"
  warn "This permanently erases the device identity, saved Wi-Fi networks,"
  warn "and recorded drives (dashcam footage) on this device."
  if ! confirm "Type y to erase this device's identity and data:"; then
    info "aborted; nothing was changed"
    return 0
  fi

  # 1. Make sure nothing is uploading while we wipe.
  for proc in manage_athenad athenad uploader; do
    run as_root pkill -f "$proc" 2>/dev/null || true
  done

  # 2. Remove the cryptographic identity kept in /persist.
  for f in "${IDENTITY_FILES[@]}"; do del_path "$f"; done

  # 3. Remove identity / credential params.
  for p in "${IDENTITY_PARAMS[@]}"; do del_param "$p"; done

  # 4. Forget every saved Wi-Fi network (keys are stored in the connections).
  for d in "${NM_CONN_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
      info "forgetting saved Wi-Fi networks in ${d}"
      run as_root sh -c "rm -f \"$d\"/* 2>/dev/null" || true
    fi
  done
  have nmcli && run as_root nmcli radio wifi off || true

  # 5. Erase recorded drives / dashcam footage.
  if [[ -d "$REALDATA_DIR" ]]; then
    info "erasing recorded drives in ${REALDATA_DIR}"
    run as_root sh -c "rm -rf \"$REALDATA_DIR\"/* 2>/dev/null" || true
  fi

  # 6. Turn SSH off on the way out.
  set_param SshEnabled "0"

  info "identity wiped."
  log ""
  log "  ${BOLD}Note:${NC} this is not a full factory reset. To also erase the OS"
  log "  state and settings, run the built-in reset (system/ui/reset.py) or use"
  log "  the Reset option in device settings before handing off the hardware."
}

# ----- argument parsing ------------------------------------------------------
DO_NET=false
DO_HARDEN=false
DO_WIPE=false
MODE_GIVEN=false

[[ $# -eq 0 ]] && { usage; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable-network) DO_NET=true;    MODE_GIVEN=true ;;
    --harden)          DO_HARDEN=true; MODE_GIVEN=true ;;
    --wipe-identity)   DO_WIPE=true;   MODE_GIVEN=true ;;
    --all)             DO_NET=true; DO_HARDEN=true; MODE_GIVEN=true ;;
    -n|--dry-run)      DRY_RUN=true ;;
    -y|--yes)          ASSUME_YES=true ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

$MODE_GIVEN || die "no mode selected (try --help)"

assert_device

$DRY_RUN && warn "dry-run: no changes will be made"

# Order matters: harden + disable-network first, wipe last.
$DO_HARDEN && harden
$DO_NET    && disable_network
$DO_WIPE   && wipe_identity

info "${BOLD}done.${NC}"
