import 'dart:io';

import 'package:car_cam/desktop/car_network.dart';
import 'package:car_cam/desktop/car_session.dart';
import 'package:car_cam/desktop/car_store.dart';
import 'package:car_cam/desktop/desktop_app.dart';
import 'package:car_cam/desktop/stream_bridge.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/video_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNetwork implements CarNetwork {
  FakeNetwork({this.single = false});

  /// Only the built-in adapter, on the home Wi-Fi: no spare one.
  final bool single;
  final joins = <(String, String)>[];
  final takeOvers = <bool>[];
  final leaves = <String>[];
  String? onCar;

  @override
  Future<List<WifiAdapter>> adapters() async => [
    if (single)
      WifiAdapter(
        device: 'wlp2s0',
        state: 'connected',
        connection: onCar ?? 'Home',
        ssid: onCar ?? 'Home',
        address: onCar == null ? '192.168.1.20' : '192.168.169.3',
        carriesDefaultRoute: onCar == null,
      ),
    if (!single)
      const WifiAdapter(
        device: 'wlp2s0',
        state: 'connected',
        connection: 'Home',
        ssid: 'Home',
        address: '192.168.1.20',
        carriesDefaultRoute: true,
      ),
    if (!single)
      WifiAdapter(
        device: 'wlx1',
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
    joins.add((device, ssid));
    takeOvers.add(takeOver);
    onCar = ssid;
    return (await adapters()).last;
  }

  @override
  Future<void> leave(String device) async {
    leaves.add(device);
    onCar = null;
  }
}

void main() {
  testWidgets('scans, lists cars, connects on the free adapter only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    final dir = Directory.systemTemp.createTempSync('ui');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CarStore(File('${dir.path}/cars.json'));
    await tester.runAsync(() async {
      await store.load();
      await store.remember('757-M64 D4E5F6', 'wlx1');
      await store.rename('757-M64 D4E5F6', "Son's car");
    });
    final net = FakeNetwork();
    final sessions = <CarSession>[];

    await tester.runAsync(() async {
      await tester.pumpWidget(
        DesktopApp(
          network: net,
          store: store,
          bridge: StreamBridge(preferredPort: 18870),
          sessionFactory: ({required label, device, bridge}) {
            final s = CarSession(
              label: label,
              device: device,
              bridge: bridge,
              folders: MediaFolders(
                Directory('${dir.path}/p'),
                Directory('${dir.path}/v'),
              ),
              // Nothing listens here: the screen shows "Starting video".
              client: CarVideoClient(
                carAddress: InternetAddress.loopbackIPv4,
                portOverrides: {CameraFamily.bl608: 9, CameraFamily.bl618: 9},
                listenForBusy: false,
              ),
            );
            sessions.add(s);
            return s;
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // The saved name shows, both cars are in range, the free dongle is chosen.
    expect(find.text("Son's car"), findsOneWidget);
    expect(find.text('757-M64 A1B2C3'), findsOneWidget);
    expect(find.textContaining('wlx1'), findsWidgets);
    expect(find.textContaining('http://localhost:188'), findsOneWidget);
    expect(find.text('Pick a car on the left'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Connect').first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(net.joins, [('wlx1', '757-M64 A1B2C3')]);
    expect(sessions.single.device, 'wlx1');
    expect(find.textContaining('Connected on wlx1'), findsOneWidget);
    expect(find.text('Starting video…'), findsOneWidget);
    expect(store.find('757-M64 A1B2C3'), isNotNull);

    // Full screen: the window is asked to fill the screen and only the video
    // shows. Esc brings everything back; a double click toggles it too.
    final windowCalls = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('car_cam/window'),
      (call) async {
        windowCalls.add('${call.method}:${call.arguments}');
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('car_cam/window'),
        null,
      ),
    );
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    expect(windowCalls, ['setFullScreen:true']);
    expect(find.byTooltip('Connect'), findsNothing);
    expect(find.byTooltip('Take photo'), findsNothing);
    expect(find.textContaining('http://localhost:188'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(windowCalls.last, 'setFullScreen:false');
    expect(find.byTooltip('Take photo'), findsOneWidget);
    expect(find.textContaining('http://localhost:188'), findsOneWidget);
    final video = find.byKey(const ValueKey('camera-video'));
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 400));
    expect(windowCalls.last, 'setFullScreen:true');
    expect(find.byTooltip('Take photo'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(windowCalls, hasLength(4));

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Disconnect'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(net.leaves, ['wlx1']);
    expect(find.text('Pick a car on the left'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  testWidgets('with one Wi-Fi adapter, asks, then switches it to the car', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    final dir = Directory.systemTemp.createTempSync('ui1');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CarStore(File('${dir.path}/cars.json'));
    await tester.runAsync(store.load);
    final net = FakeNetwork(single: true);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        DesktopApp(
          network: net,
          store: store,
          bridge: StreamBridge(preferredPort: 18872),
          sessionFactory: ({required label, device, bridge}) => CarSession(
            label: label,
            device: device,
            bridge: bridge,
            folders: MediaFolders(
              Directory('${dir.path}/p'),
              Directory('${dir.path}/v'),
            ),
            client: CarVideoClient(
              carAddress: InternetAddress.loopbackIPv4,
              portOverrides: {CameraFamily.bl608: 9, CameraFamily.bl618: 9},
              listenForBusy: false,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.textContaining('wlp2s0'), findsWidgets);
    expect(
      find.textContaining('A second Wi-Fi adapter keeps it on'),
      findsOneWidget,
    );
    expect(find.textContaining('dongle'), findsNothing);

    // Cancel leaves everything alone.
    await tester.tap(find.byTooltip('Connect').first);
    await tester.pumpAndSettle();
    expect(find.text('Use this Wi-Fi for the car?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(net.joins, isEmpty);

    await tester.tap(find.byTooltip('Connect').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to the car'));
    // The connect flow started in the test zone: let its real I/O finish.
    for (
      var i = 0;
      i < 10 && find.byTooltip('Disconnect').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(net.joins, [('wlp2s0', '757-M64 A1B2C3')]);
    expect(net.takeOvers, [true]);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Disconnect'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(net.leaves, ['wlp2s0']);

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}
