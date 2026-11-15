WiFi-Dongle-Install: AIC8800D80 USB Wi-Fi dongle
================================================

For the small USB Wi-Fi 6 + Bluetooth dongle (AX900 type, AICSemi
AIC8800D80). It first shows up as a CD drive (USB a69c:5721) and switches
to Wi-Fi (a69c:8d80) once its driver is installed.

You only need this if you use this dongle. Car Cam itself works with any
second Wi-Fi adapter that Linux or Windows already supports.

Linux (Ubuntu 24.04 tested)
    cd Linux
    ./install-aic8800d80.sh               install (asks for your password)
    ./install-aic8800d80.sh --uninstall   remove it again

  Needs internet: it downloads the community driver
  github.com/kilam994/aic8800d80-linux-driver at commit 65f74cc (the one
  tested with this dongle), builds it with DKMS (rebuilt automatically on
  kernel updates), installs the firmware and the rule that switches the
  dongle from CD to Wi-Fi. Then unplug and replug the dongle;
  "nmcli device" should list a new wifi device named wlx...

Windows
  The driver comes on the dongle itself: plug it in, open the CD drive
  that appears, and run its setup program. The Windows folder here (when
  present) holds a copy of that CD's driver for PCs without the dongle's
  CD; install it with Device Manager > Update driver > Browse, or with
      pnputil /add-driver <file>.inf /install
