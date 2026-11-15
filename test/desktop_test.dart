import 'dart:io';
import 'dart:typed_data';

import 'package:car_cam/desktop/avi_writer.dart';
import 'package:car_cam/desktop/car_network.dart';
import 'package:car_cam/desktop/car_session.dart';
import 'package:car_cam/desktop/car_store.dart';
import 'package:car_cam/desktop/jpeg_size.dart';
import 'package:car_cam/desktop/stream_bridge.dart';
import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/jpeg_header.dart';
import 'package:car_cam/protocol/video_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_car.dart';

Uint8List body(int size) => Uint8List.fromList(List.generate(size, (i) => i & 0xFF));

/// A scripted `nmcli`: answers by the first matching argument prefix and
/// records every call.
class FakeNmcli {
  FakeNmcli(this.answers);

  final Map<String, String> answers;
  final calls = <List<String>>[];

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    final line = [exe, ...args].join(' ');
    String? best;
    for (final k in answers.keys) {
      if (line.startsWith(k) && (best == null || k.length > best.length)) best = k;
    }
    return ProcessResult(0, 0, best == null ? '' : answers[best]!, '');
  }
}

void main() {
  group('nmcli parsing', () {
    test('splits escaped terse fields', () {
      expect(splitTerse(r'a\:b:c\\d:'), ['a:b', r'c\d', '']);
    });

    test('scan keeps only cars, strongest first, one per name', () {
      final cars = NetworkManagerCarNetwork.parseScan(
        '757-M64 A1B2C3:94:\n'
        'HomeWifi:70:WPA2\n'
        '757-M64 11AA22:40:WPA2\n'
        '757-M64 A1B2C3:60:\n'
        ':30:\n',
      );
      expect(cars.map((c) => c.ssid), ['757-M64 A1B2C3', '757-M64 11AA22']);
      expect(cars.first.signal, 94);
      expect(cars.first.secured, isFalse);
      expect(cars.last.secured, isTrue);
    });

    test('profile names follow the existing car-<suffix> style', () {
      expect(NetworkManagerCarNetwork.profileNameFor('757-M64 A1B2C3'), 'car-A1B2C3');
    });
  });

  group('joining', () {
    FakeNmcli nm({required bool carProfileExists, bool defaultViaDongle = false}) {
      var joined = false;
      final f = FakeNmcli({
        'ip -4 route show default': 'default via 192.168.1.1 dev wlp2s0\n',
        'nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status':
            'wlp2s0:wifi:connected:Home\nwlx1:wifi:disconnected:--\nenp3s0:ethernet:unavailable:\n',
        'nmcli -g 802-11-wireless.ssid connection show id Home': 'Home\n',
        'nmcli -g 802-11-wireless.ssid connection show id car-A1B2C3': '757-M64 A1B2C3\n',
        'nmcli -t -f NAME,UUID,TYPE connection show': carProfileExists
            ? 'Home:11111111-1111-1111-1111-111111111111:802-11-wireless\n'
                  'car-A1B2C3:22222222-2222-2222-2222-222222222222:802-11-wireless\n'
            : 'Home:11111111-1111-1111-1111-111111111111:802-11-wireless\n',
        'nmcli connection add': "Connection 'car-A1B2C3' "
            '(33333333-3333-3333-3333-333333333333) successfully added.\n',
        'nmcli -t -f GENERAL.CONNECTION,IP4.ADDRESS device show wlx1':
            'GENERAL.CONNECTION:car-A1B2C3\nIP4.ADDRESS[1]:192.168.169.3/24\n',
        'nmcli -t -f GENERAL.CONNECTION,IP4.ADDRESS device show wlp2s0':
            'GENERAL.CONNECTION:Home\nIP4.ADDRESS[1]:192.168.1.234/24\n',
      });
      return FakeNmcli({})
        ..answers.addAll(f.answers)
        ..answers['nmcli --wait 30 connection up'] = ''
        .._afterUp = () {
          joined = true;
          f.answers['nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status'] =
              'wlp2s0:wifi:connected:Home\nwlx1:wifi:connected:car-A1B2C3\n';
          if (defaultViaDongle) {
            f.answers['ip -4 route show default'] = 'default via 192.168.169.1 dev wlx1\n';
          }
        }
        .._source = f
        .._joined = () => joined;
    }

    test('a new car gets a profile that can never take the internet', () async {
      final fake = nm(carProfileExists: false);
      final net = NetworkManagerCarNetwork(run: fake.run);
      final a = await net.join('wlx1', '757-M64 A1B2C3');
      expect(a.onCar, isTrue);
      expect(a.address, '192.168.169.3');
      final add = fake.calls.firstWhere((c) => c.contains('add'));
      String setting(String k) => add[add.indexOf(k) + 1];
      expect(setting('con-name'), 'car-A1B2C3');
      expect(setting('connection.interface-name'), 'wlx1');
      expect(setting('ipv4.never-default'), 'yes');
      expect(setting('ipv4.ignore-auto-dns'), 'yes');
      expect(setting('connection.autoconnect'), 'no');
      expect(setting('ipv6.method'), 'ignore');
      final up = fake.calls.firstWhere((c) => c.contains('up'));
      expect(up, containsAllInOrder(['uuid', '33333333-3333-3333-3333-333333333333', 'ifname', 'wlx1']));
      // The internet adapter is never touched.
      expect(fake.calls.where((c) => c.contains('wlp2s0') && !c.contains('show')), isEmpty);
    });

    test('an existing profile is found by SSID and made safe again', () async {
      final fake = nm(carProfileExists: true);
      final net = NetworkManagerCarNetwork(run: fake.run);
      await net.join('wlx1', '757-M64 A1B2C3');
      expect(fake.calls.where((c) => c.contains('add')), isEmpty);
      final modify = fake.calls.firstWhere((c) => c.contains('modify'));
      expect(modify, containsAllInOrder(['22222222-2222-2222-2222-222222222222', 'ipv4.never-default', 'yes']));
    });

    test('refuses an adapter that carries another network', () async {
      final fake = nm(carProfileExists: true);
      final net = NetworkManagerCarNetwork(run: fake.run);
      await expectLater(net.join('wlp2s0', '757-M64 A1B2C3'), throwsA(isA<CarNetworkException>()));
      expect(fake.calls.where((c) => c.contains('up') || c.contains('modify')), isEmpty);
    });

    test('refuses networks that are not cars', () async {
      final net = NetworkManagerCarNetwork(run: nm(carProfileExists: true).run);
      await expectLater(net.join('wlx1', 'HomeWifi'), throwsA(isA<CarNetworkException>()));
    });

    test('backs out if the car became the default route', () async {
      final fake = nm(carProfileExists: true, defaultViaDongle: true);
      final net = NetworkManagerCarNetwork(run: fake.run);
      await expectLater(net.join('wlx1', '757-M64 A1B2C3'), throwsA(isA<CarNetworkException>()));
      expect(fake.calls.last, ['nmcli', 'device', 'disconnect', 'wlx1']);
    });
  });

  group('car store', () {
    test('remembers, renames and forgets', () async {
      final dir = await Directory.systemTemp.createTemp('carstore');
      addTearDown(() => dir.delete(recursive: true));
      final store = CarStore(File('${dir.path}/cars.json'));
      await store.load();
      await store.remember('757-M64 A1B2C3', 'wlx1');
      await store.remember('757-M64 BBBBBB', 'wlx1');
      await store.rename('757-M64 BBBBBB', "Son's car");
      final again = CarStore(store.file);
      await again.load();
      expect(again.cars.map((c) => c.name), ['757-M64 A1B2C3', "Son's car"]);
      await again.forget('757-M64 A1B2C3');
      expect(again.cars.single.ssid, '757-M64 BBBBBB');
    });
  });

  group('AVI recording', () {
    test('writes a valid Motion-JPEG AVI', () async {
      final dir = await Directory.systemTemp.createTemp('avi');
      addTearDown(() => dir.delete(recursive: true));
      final jpeg = Uint8List.fromList([
        ...JpegHeader.build(quality: 50, width: 640, height: 360)!,
        1, 2, 3,
        0xFF, 0xD9,
      ]);
      expect(jpegSize(jpeg), (640, 360));
      final w = await AviWriter.create(File('${dir.path}/a.avi'), width: 640, height: 360);
      for (var i = 0; i < 5; i++) {
        await w.addFrame(jpeg);
      }
      expect(await w.close(), 5);
      final b = ByteData.sublistView(await w.file.readAsBytes());
      String tag(int o) => String.fromCharCodes(b.buffer.asUint8List(o, 4));
      expect(tag(0), 'RIFF');
      expect(b.getUint32(4, Endian.little), b.lengthInBytes - 8);
      expect(tag(8), 'AVI ');
      expect(tag(112), 'MJPG');
      expect(b.getUint32(48, Endian.little), 5);
      expect(tag(220), 'movi');
      final moviEnd = 220 + b.getUint32(216, Endian.little);
      expect(tag(moviEnd), 'idx1');
      // Odd-length frames are padded, and the index points at each chunk.
      final firstChunk = 220 + b.getUint32(moviEnd + 16, Endian.little);
      expect(tag(firstChunk), '00dc');
      expect(b.getUint32(firstChunk + 4, Endian.little), jpeg.length);
    });
  });

  group('stream bridge', () {
    test('serves frames as multipart JPEG on localhost', () async {
      final bridge = StreamBridge(preferredPort: 18808);
      await bridge.start();
      addTearDown(bridge.stop);
      expect(bridge.url, startsWith('http://localhost:188'));
      // A raw socket, because flutter_test replaces HttpClient with a mock.
      final sock = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
      final got = <int>[];
      sock.listen(got.addAll);
      sock.write('GET /car.mjpg HTTP/1.1\r\nHost: localhost\r\n\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(String.fromCharCodes(got), contains('multipart/x-mixed-replace; boundary=carcamframe'));
      expect(bridge.viewers, 1);
      bridge.addFrame(Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        String.fromCharCodes(got),
        allOf(contains('--carcamframe\r\n'), contains('Content-Type: image/jpeg\r\nContent-Length: 6\r\n\r\n')),
      );
      sock.destroy();
    });

    test('moves to the next port if the first is taken', () async {
      final a = StreamBridge(preferredPort: 18820);
      final b = StreamBridge(preferredPort: 18820);
      await a.start();
      await b.start();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      expect(b.port, 18821);
    });
  });

  group('session against the simulated car', () {
    test('pinned to an interface, saves photo and video', () async {
      final car = await FakeCar.start(body(6000));
      addTearDown(car.close);
      final dir = await Directory.systemTemp.createTemp('session');
      addTearDown(() => dir.delete(recursive: true));
      final bridge = StreamBridge(preferredPort: 18830);
      await bridge.start();
      addTearDown(bridge.stop);
      final s = CarSession(
        label: "Son's car",
        device: 'lo',
        bridge: bridge,
        folders: MediaFolders(Directory('${dir.path}/p'), Directory('${dir.path}/v')),
        client: CarVideoClient(
          carAddress: InternetAddress.loopbackIPv4,
          portOverrides: {CameraFamily.bl608: car.port, CameraFamily.bl618: 9},
          // The interface pin itself: SO_BINDTODEVICE to loopback.
          bindDevice: Platform.isLinux ? 'lo' : null,
          listenForBusy: false,
        ),
      );
      await s.start();
      for (var i = 0; i < 100 && s.latest == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(s.latest, isNotNull);
      final photo = await s.takePhoto();
      expect(photo!.path, contains("Sons car"));
      expect(await photo.length(), s.latest!.length);
      await s.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rec = await s.stopRecording();
      expect(rec!.$2, greaterThan(0));
      expect(rec.$1.path, endsWith('.avi'));
      await s.dispose();
    });
  });
}

extension on FakeNmcli {
  static final _hooks = Expando<_Hooks>();
  _Hooks get _h => _hooks[this] ??= _Hooks();
  set _afterUp(void Function() f) => _h.afterUp = f;
  set _source(FakeNmcli f) => _h.source = f;
  set _joined(bool Function() f) => _h.joined = f;

  /// Delegates to the source answers, switching state once `up` runs.
  Future<ProcessResult> run(String exe, List<String> args) async {
    final h = _h;
    final r = await h.source!.call(exe, args);
    calls.add([exe, ...args]);
    if (args.contains('up')) h.afterUp?.call();
    return r;
  }
}

class _Hooks {
  void Function()? afterUp;
  FakeNmcli? source;
  bool Function()? joined;
}
