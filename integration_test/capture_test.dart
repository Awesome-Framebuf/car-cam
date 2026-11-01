import 'dart:convert';

import 'package:car_cam/capture/capture_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_frames.dart';

// Runs the native capture code on a device. The workflow then pulls the saved
// files off the device and checks them with ffprobe.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saves a photo and a playable video', (tester) async {
    const capture = CaptureService();
    final frames = testFramesBase64.map(base64Decode).toList();

    await tester.runAsync(() async {
      // Gives the workflow time to grant the Android 9 storage permission.
      await Future<void>.delayed(const Duration(seconds: 5));

      const limit = Duration(seconds: 90);
      await capture.savePhoto(frames[0]).timeout(limit);

      await capture.startRecording().timeout(limit);
      final clock = Stopwatch()..start();
      for (var i = 0; i < 90; i++) {
        capture.addFrame(frames[(i ~/ 15) % 2], clock.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 33));
      }
      final written = await capture.stopRecording().timeout(limit);
      expect(written, greaterThan(30));
    });
  });
}
