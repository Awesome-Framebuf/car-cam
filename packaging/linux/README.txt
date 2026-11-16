Car Cam for Linux
=================

Install (one step, asks for your password):

    ./install.sh

This installs the camera app only, no Wi-Fi driver. Remove it with
./install.sh --uninstall.

Run without installing:

    ./bundle/car_cam

Use (any Wi-Fi adapter works, including the one built into your computer):
  1. Switch the car on, press "Scan for cars", then Connect next to the car.
     With only one Wi-Fi adapter, Car Cam asks first, then switches it from
     your home Wi-Fi to the car; the internet is off until you disconnect
     or close the app, which switches it back. With a second Wi-Fi adapter,
     pick that one and your internet stays on: the car never becomes your
     internet route.
  2. Photo and record buttons are on the right of the picture.
     Photos: Pictures/Car Cam. Videos (.avi): Videos/Car Cam.
  3. Full screen: the button at the top right, a double-click on the video,
     or F11. Esc leaves it.
  4. VLC: Media > Open Network Stream > http://localhost:8808/car.mjpg
     (if 8808 is busy the app uses the next port; it shows the address at
     the bottom of the window).
