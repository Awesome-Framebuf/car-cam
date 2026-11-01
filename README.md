# Car Cam

A video-only viewer for the camera on the **NQD 1:64 Desktop Drift** camera car,
which carries an **FPV BOX HD 1080** camera on its roof. Open the app and the
camera fills the screen. There are no driving controls, accounts or cloud
services.

| The car and camera | The box |
| --- | --- |
| ![Yellow NQD drift car with a black FPV BOX HD 1080 camera on its roof](docs/images/car-with-camera.jpg) | ![NQD Desktop Drift 1:64 box showing four camera cars](docs/images/box.jpg) |

This is an independent project for owners of the car, and isn't affiliated with
or endorsed by the manufacturer.

## Versions

| | v1 | v2 |
| --- | --- | --- |
| Live video | Yes | Yes |
| Take photos | No | Yes |
| Record video | No | Yes |
| Connection guide in the app | No | Yes |
| Download | [v1.0.0](../../releases/tag/v1.0.0) | Coming soon, still in testing |

## Install

Download the files for the version you want from the table above.

**Android:** install `CarCam.apk`. New builds install over old ones.

**iPhone:** Apple requires apps to be signed, and `CarCam-unsigned.ipa` isn't.
Sign and install it with one of these:

- **AltStore or Sideloadly with a free Apple ID:** the app expires after 7 days
  and needs re-signing.
- **A paid Apple Developer account ($99 a year):** install lasts up to a year,
  and CI could be extended to sign builds and send them to TestFlight.

## Use

1. Turn the car on.
2. Join the car's Wi-Fi on your phone.
3. Open Car Cam.

Android may warn that the network has no internet. Choose to stay connected. On
iPhone, allow **Local Network** access the first time you're asked.

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
| `lib/main.dart` | The full-screen video screen |
| `test/fake_car.dart` | Simulated car used by the tests |
| `docs/PROTOCOL.md` | The wire protocol |
