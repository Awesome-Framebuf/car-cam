Car Cam for Linux
=================

Install (one step, asks for your password):

    ./install.sh

This installs the app. Remove it with ./install.sh --uninstall.

Car Cam needs a second Wi-Fi adapter for the car, so your internet stays
on the first one. The installer checks that one is free. If you use the
AIC8800D80 (AX900) USB dongle, install its driver first with the separate
WiFi-Dongle-Install package (WiFi-Dongle/Linux/install-aic8800d80.sh).

Run without installing:

    ./bundle/car_cam

Use:
  1. Plug in the USB Wi-Fi dongle. Keep your internet on your normal Wi-Fi
     or cable: the app never makes the car your internet route.
  2. Switch the car on, pick the dongle, press "Scan for cars", then Connect.
  3. Photo and record buttons are on the right of the picture.
     Photos: Pictures/Car Cam. Videos (.avi): Videos/Car Cam.
  4. VLC: Media > Open Network Stream > http://localhost:8808/car.mjpg
     (if 8808 is busy the app uses the next port; it shows the address at
     the bottom of the window).
