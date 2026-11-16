// Renders the desktop app's real widgets into docs/images for the README.
//
// These are stand-ins until real screenshots are taken: the screens are the
// real DesktopApp, but the Wi-Fi adapters and cars come from a fake network,
// and the video is the drawn road from screenshots_test.dart, labelled
// "Simulated picture".
//
// Regenerate with: flutter test tool/desktop_screenshots_test.dart --update-goldens
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:car_cam/desktop/car_network.dart';
import 'package:car_cam/desktop/car_session.dart';
import 'package:car_cam/desktop/car_store.dart';
import 'package:car_cam/desktop/desktop_app.dart';
import 'package:car_cam/desktop/stream_bridge.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart' as phone;

/// Two adapters: the built-in one on the home Wi-Fi, and a free USB dongle.
class FakeNetwork implements CarNetwork {
  String? onCar;

  @override
  Future<List<WifiAdapter>> adapters() async => [
    const WifiAdapter(
      device: 'wlp2s0',
      state: 'connected',
      connection: 'Home',
      ssid: 'Home',
      address: '192.168.1.20',
      carriesDefaultRoute: true,
    ),
    WifiAdapter(
      device: 'wlan1',
      state: onCar == null ? 'disconnected' : 'connected',
      ssid: onCar,
      address: onCar == null ? null : '192.168.169.3',
    ),
  ];

  @override
  Future<List<ScannedCar>> scan(String device) async => const [
    ScannedCar(ssid: '757-M64 A1B2C3', signal: 90, secured: false),
    ScannedCar(ssid: '757-M64 D4E5F6', signal: 40, secured: false),
  ];

  @override
  Future<WifiAdapter> join(
    String device,
    String ssid, {
    String? password,
    bool takeOver = false,
  }) async {
    onCar = ssid;
    return (await adapters()).last;
  }

  @override
  Future<void> leave(String device) async => onCar = null;
}

/// Sends the same picture ten times a second instead of talking to a car.
class PictureClient extends CarVideoClient {
  PictureClient(this.picture) : super(listenForBusy: false);

  final Uint8List picture;
  final _out = StreamController<Uint8List>.broadcast();
  Timer? _timer;

  @override
  Stream<Uint8List> get frames => _out.stream;

  @override
  Future<void> start() async {
    _out.add(picture);
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _out.add(picture),
    );
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async => stop();
}

/// The drawn road with "Simulated picture" written on it, as PNG bytes.
Future<Uint8List> labelledPicture() async {
  final road = await phone.simulatedPicture();
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawImage(road, Offset.zero, Paint());
  final pb =
      ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: 'Roboto', fontSize: 16))
        ..pushStyle(ui.TextStyle(color: Colors.white))
        ..addText('Simulated picture');
  final p = pb.build()..layout(const ui.ParagraphConstraints(width: 300));
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(12, 12, p.maxIntrinsicWidth + 16, p.height + 8),
      const Radius.circular(4),
    ),
    Paint()..color = const Color(0x99000000),
  );
  c.drawParagraph(p, const Offset(20, 16));
  final image = await recorder.endRecording().toImage(road.width, road.height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final fonts = '$root/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final roboto = FontLoader('Roboto');
    for (final w in ['Regular', 'Medium', 'Bold']) {
      final bytes = File('$fonts/Roboto-$w.ttf').readAsBytesSync();
      roboto.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await roboto.load();
    await phone.loadFont('MaterialIcons', '$fonts/MaterialIcons-Regular.otf');
  });

  testWidgets('desktop screens', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('shots');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CarStore(File('${dir.path}/cars.json'));
    final picture = (await tester.runAsync(() async {
      await store.load();
      await store.remember('757-M64 D4E5F6', 'wlan1');
      await store.rename('757-M64 D4E5F6', "Son's car");
      return labelledPicture();
    }))!;

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('car_cam/window'),
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('car_cam/window'),
        null,
      ),
    );

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    Future<void> shot(String name) => expectLater(
      find.byType(DesktopApp),
      matchesGoldenFile('../docs/images/$name.png'),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        DesktopApp(
          network: FakeNetwork(),
          store: store,
          bridge: StreamBridge(preferredPort: 8808),
          sessionFactory: ({required label, device, bridge}) => CarSession(
            label: label,
            device: device,
            bridge: bridge,
            folders: MediaFolders(
              Directory('${dir.path}/p'),
              Directory('${dir.path}/v'),
            ),
            client: PictureClient(picture),
          ),
        ),
      );
    });
    await settle();
    await shot('desktop-car-picker');

    await tester.runAsync(
      () async => tester.tap(find.byTooltip('Connect').first),
    );
    await settle();
    await shot('desktop-live');

    await tester.tap(find.byIcon(Icons.fullscreen));
    await settle();
    await shot('desktop-full-screen');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Disconnect'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}
