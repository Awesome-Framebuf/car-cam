Car Cam for Linux
=================

Install (one step, asks for your password):

    ./install.sh

This installs the app, and if your USB Wi-Fi dongle is an AIC8800D80 (for
example the UGREEN AX900 type that first shows up as a CD drive) it also
builds its driver and installs the rule that switches it from CD to Wi-Fi.
Skip the driver with ./install.sh --no-driver. Remove the app with
./install.sh --uninstall.

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
