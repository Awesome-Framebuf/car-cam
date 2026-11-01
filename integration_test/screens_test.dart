import 'dart:convert';
import 'dart:io';

import 'package:car_cam/main.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/video_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/fake_car.dart';
import 'screen_frame.dart';

// Walks through the real app against a simulated car on this device, holding
// each screen long enough for the workflow's screenshots to catch it.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('the app, screen by screen', (tester) async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    final car = await FakeCar.start(base64Decode(screenFrameBase64))
      ..silent = true;
    final client = CarVideoClient(
      carAddress: InternetAddress.loopbackIPv4,
      portOverrides: {CameraFamily.bl618: car.port, CameraFamily.bl608: 9},
      listenForBusy: false,
    );

    Future<void> hold(int seconds) async {
      for (var i = 0; i < seconds * 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: VideoScreen(client: client),
      ),
    );

    // No car yet: the connection guide.
    await hold(14);
    expect(find.text('Connect to your car'), findsOneWidget);

    // The car answers: live video.
    car.silent = false;
    await hold(14);
    expect(find.byTooltip('Take photo'), findsOneWidget);

    await tester.tap(find.byTooltip('Take photo'));
    await hold(9);

    await tester.tap(find.byTooltip('Record video'));
    await hold(14);
    expect(find.byTooltip('Stop recording'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop recording'));
    await hold(9);

    await tester.tap(find.byTooltip('How to connect'));
    await hold(9);
    expect(find.text('Connect to your car'), findsOneWidget);

    car.close();
  });
}
