// Headless check of the desktop parts against a car, real or simulated:
// video client, stream bridge, photo and recording.
//
//   dart run tool/desktop_smoke.dart [--device wlan1] [--seconds 10] [--out DIR]
//       [--car 127.0.0.1 --port 8800]
import 'dart:io';

import 'package:car_cam/desktop/car_session.dart';
import 'package:car_cam/desktop/stream_bridge.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/video_channel.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final device = opt('device');
  final seconds = int.tryParse(opt('seconds') ?? '') ?? 10;
  final out = Directory(opt('out') ?? '${Directory.systemTemp.path}/car-cam-smoke');
  final car = opt('car');
  final port = int.tryParse(opt('port') ?? '');

  final bridge = StreamBridge();
  await bridge.start();
  final session = CarSession(
    label: 'smoke',
    device: device,
    bridge: bridge,
    folders: MediaFolders(Directory('${out.path}/photos'), Directory('${out.path}/videos')),
    client: car == null
        ? null
        : CarVideoClient(
            carAddress: InternetAddress(car),
            portOverrides: {if (port != null) CameraFamily.bl608: port},
            bindDevice: device,
            listenForBusy: false,
          ),
  );
  await session.start();
  print('bridge: ${bridge.url}');

  final t0 = DateTime.now();
  while (session.latest == null && DateTime.now().difference(t0).inSeconds < 10) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (session.latest == null) {
    print('FAIL: no video in 10 s (packets: ${session.client.packetsReceived})');
    await session.dispose();
    await bridge.stop();
    exit(1);
  }
  print('first frame after ${DateTime.now().difference(t0).inMilliseconds} ms');
  final photo = await session.takePhoto();
  print('photo: ${photo!.path} (${await photo.length()} bytes)');

  await session.startRecording();
  final f0 = session.framesReceived;
  await Future<void>.delayed(Duration(seconds: seconds));
  final got = session.framesReceived - f0;
  final rec = await session.stopRecording();
  print('video: ${rec!.$1.path} (${rec.$2} frames, ${(got / seconds).toStringAsFixed(1)} fps)');
  print('packets: ${session.client.packetsReceived}');
  if (args.contains('--hold')) {
    print('holding the bridge open; Ctrl+C to stop');
    await ProcessSignal.sigint.watch().first;
  }
  await session.dispose();
  await bridge.stop();
}
