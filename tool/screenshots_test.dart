// Renders the app's real widgets into docs/images for the connection guide.
// Regenerate with: flutter test tool/screenshots_test.dart --update-goldens
import 'dart:io';
import 'dart:ui' as ui;

import 'package:car_cam/ui/camera_view.dart';
import 'package:car_cam/ui/connect_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  await loader.load();
}

/// A simple drawn road, standing in for the camera's picture.
Future<ui.Image> simulatedPicture() {
  const w = 640.0;
  const h = 360.0;
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  final sky = Paint()
    ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 180), [
      const Color(0xFF6FA8DC),
      const Color(0xFFD9E8F5),
    ]);
  c.drawRect(const Rect.fromLTWH(0, 0, w, 180), sky);
  c.drawRect(const Rect.fromLTWH(0, 180, w, 180), Paint()..color = const Color(0xFF6B8E4E));
  final road = Path()
    ..moveTo(290, 180)
    ..lineTo(350, 180)
    ..lineTo(620, 360)
    ..lineTo(20, 360)
    ..close();
  c.drawPath(road, Paint()..color = const Color(0xFF4A4A4A));
  final dash = Paint()..color = Colors.white;
  for (var y = 190.0; y < 360; y += 40) {
    final t = (y - 180) / 180;
    c.drawRect(Rect.fromCenter(center: Offset(320, y), width: 2 + 6 * t, height: 10 + 14 * t), dash);
  }
  return recorder.endRecording().toImage(w.toInt(), h.toInt());
}

void main() {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  late ui.Image picture;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFont('Roboto', '$fonts/Roboto-Regular.ttf');
    await loadFont('MaterialIcons', '$fonts/MaterialIcons-Regular.otf');
  });

  Future<void> shot(WidgetTester tester, String name, Widget child) async {
    tester.view.physicalSize = const Size(1600, 740);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(backgroundColor: Colors.black, body: child),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../docs/images/$name.png'),
    );
  }

  CameraView camera({
    ui.Image? image,
    bool live = true,
    bool recording = false,
    String status = '',
  }) => CameraView(
    image: image,
    isLive: live,
    statusText: status,
    isRecording: recording,
    recordingElapsed: const Duration(seconds: 42),
    isFlashing: false,
    onTakePhoto: () {},
    onToggleRecording: () {},
    onHelp: () {},
  );

  testWidgets('screens', (tester) async {
    picture = (await tester.runAsync(simulatedPicture))!;
    await shot(
      tester,
      'guide-android',
      ConnectGuide(onOpenSettings: () {}, platform: TargetPlatform.android),
    );
    await shot(
      tester,
      'guide-iphone',
      ConnectGuide(onOpenSettings: () {}, platform: TargetPlatform.iOS),
    );
    await shot(tester, 'status-starting', camera(live: false, status: 'Starting video…'));
    await shot(tester, 'live', camera(image: picture));
    await shot(tester, 'recording', camera(image: picture, recording: true));
    await shot(
      tester,
      'status-reconnecting',
      camera(image: picture, live: false, status: 'Reconnecting…'),
    );
    await shot(
      tester,
      'status-busy',
      camera(live: false, status: 'Another phone is using the car'),
    );
  });
}
