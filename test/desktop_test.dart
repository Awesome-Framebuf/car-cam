import 'dart:convert';
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
        'nmcli connection add':
            "Connection 'car-A1B2C3' "
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
      expect(
        up,
        containsAllInOrder(['uuid', '33333333-3333-3333-3333-333333333333', 'ifname', 'wlx1']),
      );
      // The internet adapter is never touched.
      expect(fake.calls.where((c) => c.contains('wlp2s0') && !c.contains('show')), isEmpty);
    });

    test('an existing profile is found by SSID and made safe again', () async {
      final fake = nm(carProfileExists: true);
      final net = NetworkManagerCarNetwork(run: fake.run);
      await net.join('wlx1', '757-M64 A1B2C3');
      expect(fake.calls.where((c) => c.contains('add')), isEmpty);
      final modify = fake.calls.firstWhere((c) => c.contains('modify'));
      expect(
        modify,
        containsAllInOrder(['22222222-2222-2222-2222-222222222222', 'ipv4.never-default', 'yes']),
      );
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

  group('Windows (netsh)', () {
    const interfaces =
        'There are 2 interfaces on the system:\r\n\r\n'
        '    Name                   : Wi-Fi\r\n'
        '    Description            : Intel(R) Wi-Fi 6 AX201 160MHz\r\n'
        '    Physical address       : aa:bb:cc:dd:ee:ff\r\n'
        '    State                  : connected\r\n'
        '    SSID                   : Home\r\n'
        '    AP BSSID               : 11:22:33:44:55:66\r\n\r\n'
        '    Name                   : Wi-Fi 2\r\n'
        '    Description            : AIC8800D80 Wireless\r\n'
        '    State                  : disconnected\r\n';
    const onCar =
        '    Name                   : Wi-Fi\r\n'
        '    State                  : connected\r\n'
        '    SSID                   : Home\r\n\r\n'
        '    Name                   : Wi-Fi 2\r\n'
        '    State                  : connected\r\n'
        '    SSID                   : 757-M64 A1B2C3\r\n';
    const networks =
        'Interface name : Wi-Fi 2\r\nThere are 4 networks currently visible.\r\n\r\n'
        'SSID 1 : 757-M64 A1B2C3\r\n'
        '    Network type            : Infrastructure\r\n'
        '    Authentication          : Open\r\n'
        '    Encryption              : None\r\n'
        '    BSSID 1                 : 90:de:80:00:00:01\r\n'
        '         Signal             : 61%\r\n'
        '    BSSID 2                 : 90:de:80:00:00:02\r\n'
        '         Signal             : 88%\r\n'
        'SSID 2 : HomeWifi\r\n'
        '    Authentication          : WPA2-Personal\r\n'
        '    BSSID 1                 : 11:22:33:44:55:66\r\n'
        '         Signal             : 99%\r\n'
        'SSID 3 : 757-M64 11AA22\r\n'
        '    Authentication          : WPA2-Personal\r\n'
        '    BSSID 1                 : 90:de:80:00:00:03\r\n'
        '         Signal             : 40%\r\n'
        'SSID 4 : \r\n'
        '    Authentication          : Open\r\n'
        '         Signal             : 30%\r\n';

    /// A scripted Windows: netsh, PowerShell and the interface addresses.
    /// [carWinsRoute] makes the car the default route after joining; with
    /// [metricFixWorks] the elevated metric fix moves it back.
    ({FakeNmcli fake, WindowsCarNetwork net, List<String> profiles}) windows({
      bool carWinsRoute = false,
      bool metricFixWorks = false,
    }) {
      final addresses = <String, String>{'Wi-Fi': '192.168.1.20'};
      final profiles = <String>[];
      late final FakeNmcli fake;
      var route = 'Wi-Fi';
      fake = FakeNmcli({
        'netsh wlan show interfaces': interfaces,
        'netsh wlan show networks': networks,
        'powershell -NoProfile -NonInteractive -Command Get-NetRoute': 'Wi-Fi\r\n',
      });
      Future<ProcessResult> run(String exe, List<String> args) async {
        final r = await fake.call(exe, args);
        final line = [exe, ...args].join(' ');
        if (line.startsWith('netsh wlan add profile')) {
          final path = args.firstWhere((a) => a.startsWith('filename=')).substring(9);
          profiles.add(await File(path).readAsString());
        } else if (line.startsWith('netsh wlan connect')) {
          addresses['Wi-Fi 2'] = '192.168.169.3';
          fake.answers['netsh wlan show interfaces'] = onCar;
          if (carWinsRoute) route = 'Wi-Fi 2';
        } else if (line.contains('Start-Process powershell -Verb RunAs')) {
          if (metricFixWorks) route = 'Wi-Fi';
        }
        if (line.contains('Get-NetRoute')) return ProcessResult(0, 0, '$route\r\n', '');
        return r;
      }

      final net = WindowsCarNetwork(
        run: run,
        addresses: () async => Map.of(addresses),
        pollInterval: Duration.zero,
        addressTimeout: const Duration(seconds: 2),
        rescanDelay: Duration.zero,
      );
      return (fake: fake, net: net, profiles: profiles);
    }

    test('lists adapters with state, SSID and the internet route', () async {
      final w = windows();
      final list = await w.net.adapters();
      expect(list.map((a) => a.device), ['Wi-Fi', 'Wi-Fi 2']);
      expect(list.first.carriesDefaultRoute, isTrue);
      expect(list.first.isFree, isFalse);
      expect(list.last.isFree, isTrue);
      expect(list.last.state, 'disconnected');
    });

    test('scan keeps only cars, strongest first, one per name', () async {
      final w = windows();
      final cars = await w.net.scan('Wi-Fi 2');
      expect(cars.map((c) => c.ssid), ['757-M64 A1B2C3', '757-M64 11AA22']);
      expect(cars.first.signal, 88);
      expect(cars.first.secured, isFalse);
      expect(cars.last.secured, isTrue);
      expect(w.fake.calls.first, contains('interface=Wi-Fi 2'));
    });

    test('join writes a manual open profile, adds it, then connects', () async {
      final w = windows();
      final a = await w.net.join('Wi-Fi 2', '757-M64 A1B2C3');
      expect(a.onCar, isTrue);
      expect(a.address, '192.168.169.3');
      final xml = w.profiles.single;
      expect(xml, contains('<name>car-A1B2C3</name>'));
      expect(xml, contains('<connectionMode>manual</connectionMode>'));
      expect(xml, contains('<authentication>open</authentication><encryption>none</encryption>'));
      expect(xml, contains('<name>757-M64 A1B2C3</name>'));
      final cmds = w.fake.calls.map((c) => c.join(' ')).toList();
      final add = cmds.indexWhere((c) => c.startsWith('netsh wlan add profile'));
      final connect = cmds.indexWhere((c) => c.startsWith('netsh wlan connect'));
      expect(add, isNonNegative);
      expect(connect, greaterThan(add));
      expect(cmds[add], contains('interface=Wi-Fi 2'));
      expect(w.fake.calls[connect], [
        'netsh',
        'wlan',
        'connect',
        'name=car-A1B2C3',
        'ssid=757-M64 A1B2C3',
        'interface=Wi-Fi 2',
      ]);
      // The internet adapter is never touched, and no elevation was needed.
      expect(w.fake.calls.where((c) => c.contains('interface=Wi-Fi')), isEmpty);
      expect(cmds.where((c) => c.contains('RunAs')), isEmpty);
    });

    test('profile XML escapes the SSID and carries a password', () {
      final xml = WindowsCarNetwork.profileXml('757-<A&B>', password: 'p&ss');
      expect(xml, contains('<name>757-&lt;A&amp;B&gt;</name>'));
      expect(xml, contains('<authentication>WPA2PSK</authentication><encryption>AES</encryption>'));
      expect(xml, contains('<keyMaterial>p&amp;ss</keyMaterial>'));
      expect(xml, isNot(contains('757-<A&B>')));
    });

    test('refuses an adapter that carries another network', () async {
      final w = windows();
      await expectLater(w.net.join('Wi-Fi', '757-M64 A1B2C3'), throwsA(isA<CarNetworkException>()));
      expect(w.fake.calls.where((c) => c.contains('connect') || c.contains('add')), isEmpty);
    });

    test('refuses networks that are not cars', () async {
      final w = windows();
      await expectLater(w.net.join('Wi-Fi 2', 'HomeWifi'), throwsA(isA<CarNetworkException>()));
      expect(w.fake.calls, isEmpty);
    });

    test('fixes the metric once if the car wins the route', () async {
      final w = windows(carWinsRoute: true, metricFixWorks: true);
      final a = await w.net.join('Wi-Fi 2', '757-M64 A1B2C3');
      expect(a.onCar, isTrue);
      expect(w.fake.calls.where((c) => c.join(' ').contains('RunAs')), hasLength(1));
      expect(w.fake.calls.where((c) => c.contains('disconnect')), isEmpty);
    });

    test('disconnects and throws if the car stays the default route', () async {
      final w = windows(carWinsRoute: true);
      await expectLater(
        w.net.join('Wi-Fi 2', '757-M64 A1B2C3'),
        throwsA(isA<CarNetworkException>()),
      );
      expect(w.fake.calls.last, ['netsh', 'wlan', 'disconnect', 'interface=Wi-Fi 2']);
    });

    test('the elevated metric fix carries no quotes through Start-Process', () {
      final cmd = WindowsCarNetwork.metricFixCommand("Wi-Fi 2");
      expect(cmd, startsWith('Start-Process powershell -Verb RunAs'));
      expect(cmd, contains('-EncodedCommand'));
      final b64 = RegExp(r"'([A-Za-z0-9+/=]+)'$").firstMatch(cmd)!.group(1)!;
      final bytes = base64.decode(b64);
      final inner = String.fromCharCodes([
        for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
      ]);
      expect(inner, contains("-InterfaceAlias 'Wi-Fi 2'"));
      expect(inner, contains('-InterfaceMetric 9000'));
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
        1,
        2,
        3,
        0xFF,
        0xD9,
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
      expect(
        String.fromCharCodes(got),
        contains('multipart/x-mixed-replace; boundary=carcamframe'),
      );
      expect(bridge.viewers, 1);
      bridge.addFrame(Uint8List.fromList([0xFF, 0xD8, 9, 9, 0xFF, 0xD9]));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        String.fromCharCodes(got),
        allOf(
          contains('--carcamframe\r\n'),
          contains('Content-Type: image/jpeg\r\nContent-Length: 6\r\n\r\n'),
        ),
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
