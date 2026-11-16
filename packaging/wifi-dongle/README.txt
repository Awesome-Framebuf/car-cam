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

Windows (10 and 11)
    Windows\install-aic8800d80.cmd       double-click; it asks for admin rights

  It installs the driver with pnputil: from a driver\ folder next to the
  script if there is one, otherwise from the dongle's own CD drive (it
  searches D: to Z: for an .inf that names the AIC8800 / VID_A69C /
  VID_368B). Then unplug and replug the dongle; "netsh wlan show
  interfaces" should list a second Wi-Fi adapter.

  The driver itself is the vendor's and is not included. You can also
  just open the dongle's CD drive and run its setup program, or use
  Device Manager > Update driver > Browse, or
      pnputil /add-driver <file>.inf /install
