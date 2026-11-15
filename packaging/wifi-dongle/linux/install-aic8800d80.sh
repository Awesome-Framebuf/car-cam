#!/usr/bin/env bash
# USB Wi-Fi dongle driver for Linux: AIC8800D80 (BT + Wi-Fi 6 AX900 type).
#
# The dongle first shows up as a CD drive (USB a69c:5721). This installs the
# rule that switches it to Wi-Fi (a69c:8d80), the DKMS driver (rebuilt on
# every kernel update) and its firmware.
#
#   ./install-aic8800d80.sh               install (skips if already installed)
#   ./install-aic8800d80.sh --force       reinstall
#   ./install-aic8800d80.sh --uninstall   remove driver, firmware and rule
#
# Asks for your password once (sudo). Needs internet. Tested on Ubuntu 24.04.
# Separate from Car Cam: only needed if you use this dongle.
set -Eeuo pipefail

# The community driver, pinned to the commit that was tested with the dongle.
# Checking out the full hash also verifies what was downloaded.
DRIVER_REPO=https://github.com/kilam994/aic8800d80-linux-driver.git
DRIVER_COMMIT=65f74ccbe982d9242afd1b3126a28fc3a77abb4f

MODE=install
for a in "$@"; do
  case "$a" in
    --force) MODE=force ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n 2,13p "$0"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  say "Asking for your password to install the driver."
  exec sudo -- "$0" "$@"
fi

driver_present() {
  modinfo aic8800_fdrv >/dev/null 2>&1 &&
    [[ -d /lib/firmware/aic8800D80 ]] &&
    { [[ -f /usr/lib/udev/rules.d/aic.rules ]] || [[ -f /lib/udev/rules.d/aic.rules ]]; }
}

fetch_driver() {
  command -v apt-get >/dev/null && apt-get install -y git eject usb-modeswitch
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  say "Downloading the driver (commit ${DRIVER_COMMIT:0:7})"
  git -c advice.detachedHead=false clone --quiet "$DRIVER_REPO" "$work/drv"
  git -C "$work/drv" -c advice.detachedHead=false checkout --quiet "$DRIVER_COMMIT"
  [[ "$(git -C "$work/drv" rev-parse HEAD)" == "$DRIVER_COMMIT" ]] ||
    { echo "Driver download didn't verify." >&2; exit 1; }
}

if [[ $MODE == uninstall ]]; then
  fetch_driver
  (cd "$work/drv" && ./uninstall.sh)
  ok "Driver removed. Unplug the dongle."
  exit 0
fi

if [[ $MODE == install ]] && driver_present; then
  ok "Driver, firmware and switch rule are already installed (use --force to reinstall)."
else
  fetch_driver
  say "Building and installing the driver (a few minutes)"
  # The driver's own installer: DKMS module, firmware, the udev rule that
  # ejects the dongle's CD, and the usb_modeswitch config.
  (cd "$work/drv" && ./install.sh --yes)
  if driver_present; then ok "Driver installed"; else warn "Finished with warnings; replug the dongle or reboot."; fi
fi

if lsusb 2>/dev/null | grep -qi 'a69c:5721'; then
  warn "The dongle is still in CD mode. Unplug it and plug it back in."
fi
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  warn "Secure Boot is on: if the dongle doesn't appear, reboot and enroll the DKMS key when asked."
fi
cat <<'MSG'

Check: plug in the dongle, wait 5 seconds, then run   nmcli device
A new "wifi" device named wlx... should be listed.
MSG
