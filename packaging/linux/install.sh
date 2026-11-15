#!/usr/bin/env bash
# Car Cam for Linux: one-step installer.
#
#   ./install.sh               install the app, plus the AIC8800 Wi-Fi dongle
#                              driver if it's missing
#   ./install.sh --no-driver   install the app only
#   ./install.sh --uninstall   remove the app (leaves the driver and your cars)
#
# Asks for your password once (sudo). Tested on Ubuntu 24.04.
set -Eeuo pipefail

APP_DIR=/opt/car-cam
BIN_LINK=/usr/local/bin/car-cam
DESKTOP_FILE=/usr/share/applications/car-cam.desktop
ICON_FILE=/usr/share/icons/hicolor/256x256/apps/car-cam.png

# The community AIC8800D80 driver, pinned to a commit that was tested with the
# dongle. Checking out the full hash also verifies what was downloaded.
DRIVER_REPO=https://github.com/kilam994/aic8800d80-linux-driver.git
DRIVER_COMMIT=65f74ccbe982d9242afd1b3126a28fc3a77abb4f

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WANT_DRIVER=yes
UNINSTALL=no
for a in "$@"; do
  case "$a" in
    --no-driver) WANT_DRIVER=no ;;
    --uninstall) UNINSTALL=yes ;;
    -h|--help) sed -n 2,9p "$0"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  say "Asking for your password to install system-wide."
  exec sudo -- "$0" "$@"
fi

if [[ $UNINSTALL == yes ]]; then
  rm -rf "$APP_DIR" "$BIN_LINK" "$DESKTOP_FILE" "$ICON_FILE"
  ok "Car Cam removed. Saved cars stay in ~/.config/car-cam; car Wi-Fi profiles are named car-*."
  exit 0
fi

[[ -x "$HERE/bundle/car_cam" ]] || { echo "Run this from the unpacked car-cam-linux folder." >&2; exit 1; }

have_apt=no; command -v apt-get >/dev/null && have_apt=yes

# --- Packages the app needs to run ------------------------------------------
say "Checking system packages"
pkgs=()
command -v nmcli >/dev/null || pkgs+=(network-manager)
ldconfig -p | grep -q 'libgtk-3.so.0' || pkgs+=(libgtk-3-0t64)
if [[ ${#pkgs[@]} -gt 0 ]]; then
  if [[ $have_apt == yes ]]; then
    apt-get update -qq || warn "apt-get update failed; trying anyway"
    apt-get install -y "${pkgs[@]}" || apt-get install -y "${pkgs[@]/libgtk-3-0t64/libgtk-3-0}"
  else
    warn "Please install: ${pkgs[*]}"
  fi
fi
ok "System packages"

# --- The USB Wi-Fi dongle driver (AIC8800D80) -------------------------------
driver_present() {
  modinfo aic8800_fdrv >/dev/null 2>&1 &&
    [[ -d /lib/firmware/aic8800D80 ]] &&
    { [[ -f /usr/lib/udev/rules.d/aic.rules ]] || [[ -f /lib/udev/rules.d/aic.rules ]]; }
}

if [[ $WANT_DRIVER == yes ]]; then
  say "Checking the AIC8800 USB Wi-Fi dongle driver"
  if driver_present; then
    ok "Driver, firmware and switch rule already installed"
  else
    if [[ $have_apt == yes ]]; then
      apt-get install -y git eject usb-modeswitch
    fi
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    say "Downloading the driver (commit ${DRIVER_COMMIT:0:7})"
    git -c advice.detachedHead=false clone --quiet "$DRIVER_REPO" "$work/drv"
    git -C "$work/drv" -c advice.detachedHead=false checkout --quiet "$DRIVER_COMMIT"
    [[ "$(git -C "$work/drv" rev-parse HEAD)" == "$DRIVER_COMMIT" ]] || { echo "Driver download didn't verify." >&2; exit 1; }
    say "Building and installing the driver (a few minutes)"
    # The driver's own audited installer: DKMS module, firmware, the udev rule
    # that ejects the dongle's install CD, and usb_modeswitch config.
    (cd "$work/drv" && ./install.sh --yes)
    if driver_present; then ok "Driver installed"; else warn "Driver install finished with warnings; replug the dongle or reboot."; fi
  fi
  if lsusb 2>/dev/null | grep -qiE 'a69c:57|a69c:5721'; then
    warn "The dongle is still in CD mode. Unplug it and plug it back in."
  fi
fi

# --- The app ----------------------------------------------------------------
say "Installing Car Cam to $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$HERE/bundle/." "$APP_DIR/"
cp "$HERE/install.sh" "$APP_DIR/install.sh"
ln -sf "$APP_DIR/car_cam" "$BIN_LINK"
if [[ -f "$HERE/car-cam.png" ]]; then
  mkdir -p "$(dirname "$ICON_FILE")"
  cp "$HERE/car-cam.png" "$ICON_FILE"
fi
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Car Cam
Comment=Live video from the 757 drift car's camera
Exec=$APP_DIR/car_cam
Icon=car-cam
Terminal=false
Categories=AudioVideo;Video;
EOF
command -v update-desktop-database >/dev/null && update-desktop-database -q || true
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
ok "Car Cam installed"

cat <<'EOF'

Done. Start "Car Cam" from your apps menu, or run:  car-cam

  - Plug in the USB Wi-Fi dongle, pick it in the app, scan, press Connect.
    Your internet stays on your normal Wi-Fi or cable.
  - Watch in VLC: Media > Open Network Stream > http://localhost:8808/car.mjpg
  - Photos go to Pictures/Car Cam, videos to Videos/Car Cam.
EOF
