#!/usr/bin/env bash
# Car Cam for Linux: one-step installer.
#
#   ./install.sh               install the app
#   ./install.sh --uninstall   remove the app (leaves your saved cars)
#
# Installs the camera app only, no Wi-Fi driver. Any Wi-Fi adapter works.
#
# Asks for your password once (sudo). Tested on Ubuntu 24.04.
set -Eeuo pipefail

APP_DIR=/opt/car-cam
BIN_LINK=/usr/local/bin/car-cam
DESKTOP_FILE=/usr/share/applications/car-cam.desktop
ICON_FILE=/usr/share/icons/hicolor/256x256/apps/car-cam.png

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL=no
for a in "$@"; do
  case "$a" in
    --uninstall) UNINSTALL=yes ;;
    -h|--help) sed -n 2,10p "$0"; exit 0 ;;
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

# --- Wi-Fi --------------------------------------------------------------------
# Any Wi-Fi adapter works. With only one, the app switches it to the car while
# you watch (the internet is off meanwhile); a second one keeps the internet on.
say "Checking Wi-Fi"
wifi_total=0
if command -v nmcli >/dev/null; then
  while IFS=: read -r _dev type _rest; do
    [[ $type == wifi ]] && wifi_total=$((wifi_total + 1))
  done < <(nmcli -t -f DEVICE,TYPE device 2>/dev/null)
fi
if [[ $wifi_total -gt 0 ]]; then
  ok "$wifi_total Wi-Fi adapter(s) found"
else
  warn "No Wi-Fi adapter found yet. Car Cam needs Wi-Fi to reach the car."
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

  - Switch the car on, press "Scan for cars", then Connect. With one Wi-Fi
    adapter the internet is off while you watch; a second one keeps it on.
  - Watch in VLC: Media > Open Network Stream > http://localhost:8808/car.mjpg
  - Photos go to Pictures/Car Cam, videos to Videos/Car Cam.
EOF
