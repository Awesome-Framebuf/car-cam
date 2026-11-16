# Car Cam

A video-only viewer for the camera on the **NQD 1:64 Desktop Drift** camera car,
which carries an **FPV BOX HD 1080** camera on its roof. Open the app and the
camera fills the screen. There are no driving controls, accounts or cloud
services. Version 2 can also take photos and record video.

| The car and camera | The box |
| --- | --- |
| ![Yellow NQD drift car with a black FPV BOX HD 1080 camera on its roof](docs/images/car-with-camera.jpg) | ![NQD Desktop Drift 1:64 box showing four camera cars](docs/images/box.jpg) |

**[Visit the website](https://awesome-framebuf.github.io/car-cam/)** for downloads, screenshots and videos.

This is an independent project for owners of the car, and isn't affiliated with
or endorsed by the manufacturer.

## Versions

| | v1 | v2 |
| --- | --- | --- |
| Live video | Yes | Yes |
| Take photos | No | Yes |
| Record video | No | Yes |
| Connection guide in the app | No | Yes |
| Download | [v1.0.0](../../releases/tag/v1.0.0) | [v2.0.0](../../releases/tag/v2.0.0) |

## Install

Scan with your phone's camera to download. Version 2 is the newest.

| | v2.0.0 (photos and video) | v1.0.0 (video only) |
| --- | --- | --- |
| **Android** | ![QR code for the v2.0.0 Android app](docs/images/qr/v2.0.0-android.png)<br>[CarCam.apk](../../releases/download/v2.0.0/CarCam.apk) | ![QR code for the v1.0.0 Android app](docs/images/qr/v1.0.0-android.png)<br>[CarCam.apk](../../releases/download/v1.0.0/CarCam.apk) |
| **iPhone** | ![QR code for the v2.0.0 iPhone file](docs/images/qr/v2.0.0-iphone.png)<br>[CarCam-unsigned.ipa](../../releases/download/v2.0.0/CarCam-unsigned.ipa) | ![QR code for the v1.0.0 iPhone file](docs/images/qr/v1.0.0-iphone.png)<br>[CarCam-unsigned.ipa](../../releases/download/v1.0.0/CarCam-unsigned.ipa) |

The iPhone code only downloads the file: it won't install until it's signed, as
described below.

**Android:** install `CarCam.apk`. If Android refuses to install it over another
version, uninstall the old one first.

**iPhone:** Apple requires apps to be signed, and `CarCam-unsigned.ipa` isn't.
Sign and install it with one of these:

- **AltStore or Sideloadly with a free Apple ID:** the app expires after 7 days
  and needs re-signing.
- **A paid Apple Developer account ($99 a year):** install lasts up to a year,
  and CI could be extended to sign builds and send them to TestFlight.

## Use

Turn on the car, join its Wi-Fi on your phone and open Car Cam. See the
[connection guide](docs/CONNECTING.md) for screenshots and troubleshooting.

![Car Cam showing the camera picture, drawn here, with photo and record buttons](docs/images/live.png)

## Desktop: Linux and Windows (preview)

Download from the [desktop releases](../../releases) (tags `desktop-v…`). Built
from the `desktop` branch by `.github/workflows/desktop.yml`.

You need a **second Wi-Fi adapter** for the car, such as a USB dongle, so your
internet stays on your normal Wi-Fi or cable. For the AIC8800D80 (AX900) dongle,
install its driver first with `WiFi-Dongle-Install` (also in the release).

**Linux** (x64, NetworkManager):

```sh
tar xzf car-cam-linux-x64.tar.gz
cd car-cam-linux-x64
./install.sh            # asks for your password; --uninstall removes it
```

Start **Car Cam** from the app menu, or run `./bundle/car_cam` without installing.

**Windows** (10/11, x64): run `CarCamSetup.exe` (unsigned: SmartScreen > More
info > Run anyway), then start **Car Cam** from the Start menu. Allow private
networks if the firewall asks. The installer adds no driver.

- The app joins the car without ever making it the internet route (Linux:
  NetworkManager `never-default`; Windows: a high interface metric, checked
  after joining), and refuses adapters that carry another network.
- The car picker scans for networks starting with `757-`, remembers cars, and
  lets you name them.
- Photos go to `Pictures/Car Cam`, videos (Motion-JPEG `.avi`) to `Videos/Car Cam`.
- Full screen: the button on the video, a double-click, or F11; Esc leaves it.
- VLC, OBS or a browser can open the live video at
  `http://localhost:8808/car.mjpg`. If that port is taken the app uses the next
  one and shows the address. A single picture is at `/car.jpg`.
- Tested on a real car on Linux. The Windows build is so far only built and
  unit-tested in CI.

## Develop

```sh
flutter test      # includes a fake car that streams over real UDP
flutter analyze
```

Every push to `main` runs the tests, builds both apps in GitHub Actions and
replaces the `latest` release.

| Path | Purpose |
| --- | --- |
| `lib/protocol/video_channel.dart` | Frame reassembly and acknowledgements |
| `lib/protocol/jpeg_header.dart` | Generates the JPEG header older cameras omit |
| `lib/protocol/car_video_client.dart` | Sockets and timing |
| `lib/capture/capture_service.dart` | Photo and video calls to native code |
| `lib/ui/` | The camera screen and connection guide |
| `lib/main.dart` | Ties the app together |
| `android/`, `ios/Runner/AppDelegate.swift` | Native H.264 recording and saving |
| `integration_test/` | Capture tests run on emulators and simulators |
| `tool/` | Device test scripts, the screenshot renderer and the QR code maker |
| `test/fake_car.dart` | Simulated car used by the tests |
| `docs/CONNECTING.md` | The connection guide |
| `docs/PROTOCOL.md` | The wire protocol |
