import 'package:car_cam/ui/camera_view.dart';
import 'package:car_cam/ui/connect_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

CameraView view({
  bool live = true,
  bool recording = false,
  VoidCallback? photo,
  VoidCallback? record,
}) {
  return CameraView(
    image: null,
    isLive: live,
    statusText: 'Reconnecting…',
    isRecording: recording,
    recordingElapsed: const Duration(minutes: 1, seconds: 5),
    isFlashing: false,
    onTakePhoto: photo ?? () {},
    onToggleRecording: record ?? () {},
    onHelp: () {},
  );
}

void main() {
  testWidgets('buttons work while live', (tester) async {
    var photos = 0;
    var records = 0;
    await tester.pumpWidget(
      app(view(photo: () => photos++, record: () => records++)),
    );
    await tester.tap(find.byTooltip('Take photo'));
    await tester.tap(find.byTooltip('Record video'));
    expect((photos, records), (1, 1));
  });

  testWidgets('no video means no capture', (tester) async {
    var photos = 0;
    var records = 0;
    await tester.pumpWidget(
      app(view(live: false, photo: () => photos++, record: () => records++)),
    );
    await tester.tap(find.byTooltip('Take photo'));
    await tester.tap(find.byTooltip('Record video'));
    expect((photos, records), (0, 0));
    expect(find.text('Reconnecting…'), findsOneWidget);
  });

  testWidgets('a recording can stop even if the video drops', (tester) async {
    var records = 0;
    await tester.pumpWidget(
      app(view(live: false, recording: true, record: () => records++)),
    );
    await tester.tap(find.byTooltip('Stop recording'));
    expect(records, 1);
    expect(find.text('01:05'), findsOneWidget);
  });

  for (final (platform, step) in [
    (TargetPlatform.android, 'choose to stay connected'),
    (TargetPlatform.iOS, 'Local Network'),
  ]) {
    testWidgets('guide fits a small phone on ${platform.name}', (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(
        app(ConnectGuide(onOpenSettings: () => opened++, platform: platform)),
      );
      expect(find.textContaining(step), findsWidgets);
      await tester.tap(find.byIcon(Icons.wifi));
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
