import 'dart:io';

import 'package:car_cam/desktop/car_network.dart';
import 'package:car_cam/desktop/car_session.dart';
import 'package:car_cam/desktop/car_store.dart';
import 'package:car_cam/desktop/desktop_app.dart';
import 'package:car_cam/desktop/stream_bridge.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/video_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNetwork implements CarNetwork {
  final joins = <(String, String)>[];
  final leaves = <String>[];
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
  Future<WifiAdapter> join(String device, String ssid, {String? password}) async {
    joins.add((device, ssid));
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
  testWidgets('scans, lists cars, connects on the free adapter only', (tester) async {
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
              folders: MediaFolders(Directory('${dir.path}/p'), Directory('${dir.path}/v')),
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
}
