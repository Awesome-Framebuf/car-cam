# Car Cam

A video-only viewer for the camera on an NQD Wi-Fi drift car. Open it and the
camera fills the screen. There are no controls, accounts or cloud services.

This is an independent project for owners of the car, and isn't affiliated with
or endorsed by the manufacturer.

## Install

Download the files from the [latest release](../../releases/tag/latest).

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
