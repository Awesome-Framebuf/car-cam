Car Cam for the computer: watch, photograph and record the 757 drift car's camera
on Linux or Windows, and share the live video with VLC or OBS.

You need a **second Wi-Fi adapter** for the car (a USB Wi-Fi dongle), so your
internet stays on your normal Wi-Fi or cable. The app never makes the car your
internet route.

| File | For |
| --- | --- |
| `car-cam-linux-x64.tar.gz` | Linux (x64, Ubuntu 24.04 tested) |
| `CarCamSetup.exe` | Windows 10 / 11 (x64) installer |
| `WiFi-Dongle-Install.zip` (`.tar.gz`) | Only for the AIC8800D80 (AX900) USB dongle: driver install scripts for Linux and Windows. The Windows driver itself is the vendor's and is not included. |

### Linux

```sh
tar xzf car-cam-linux-x64.tar.gz
cd car-cam-linux-x64
./install.sh            # asks for your password; ./install.sh --uninstall removes it
```
Then start **Car Cam** from the app menu (or run `car-cam`). To try it without
installing: `./bundle/car_cam`. Needs NetworkManager. For the AIC8800D80 dongle,
first run `Linux/install-aic8800d80.sh` from WiFi-Dongle-Install.

### Windows

1. For the AIC8800D80 dongle, install its driver first: plug it in and run the
   setup program on the CD drive it shows, or run
   `Windows\install-aic8800d80.cmd` from WiFi-Dongle-Install.
2. Run `CarCamSetup.exe`. Windows SmartScreen may warn because the installer is
   not signed: click **More info > Run anyway**.
3. Start **Car Cam** from the Start menu. If Windows Firewall asks, allow private
   networks.

### Use

1. Switch the car on, pick the dongle, press **Scan for cars**, then **Connect**.
2. Photo and record buttons are next to the picture. Photos go to
   `Pictures/Car Cam`, videos (`.avi`) to `Videos/Car Cam`.
3. Full screen: the button at the top right of the video, a double-click, or F11.
   Esc leaves it.
4. VLC: Media > Open Network Stream > `http://localhost:8808/car.mjpg`
   (the app shows the address at the bottom if it had to use another port).

### What was tested

- **Linux:** on a real car through an AIC8800D80 dongle (live view, photo,
  recording, VLC stream, full screen).
- **Windows:** built and unit-tested in GitHub Actions only. Not yet tried on a
  real Windows PC with the car.
