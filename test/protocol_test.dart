import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:car_cam/protocol/car_video_client.dart';
import 'package:car_cam/protocol/jpeg_header.dart';
import 'package:car_cam/protocol/video_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_car.dart';

Uint8List body(int size) =>
    Uint8List.fromList(List.generate(size, (i) => i & 0xFF));

void main() {
  group('JPEG header', () {
    // SHA-256 of the headers the original app uses at 640x360. Matching them
    // shows the generated header is byte-for-byte what the camera expects.
    const expected = {
      5: 'df9ee8fb8538f67d5f1ea85030220e4105e714be2302328435833f2d52a8c1b1',
      10: 'af72e0e8fe55ca5fa455a62c38781fbd16ce73166e3b2d7ffd9f22873148f51f',
      25: '0d24f2c66974c35d155d29befcda6791d4c3247ae36888da6f25629d264541cb',
      50: 'ef4c70ec8777ed2036923d0ad059dc9b44bed96ecdba38be62f1243dc7307a17',
      75: '4fd75a4cf4141f0a4a9666ce537f38da541744bccb9e7656400156a06b132e63',
      100: 'aa02c7b99cf81bb695f325835fca17ab7cbed7d2dd14448d3f52d7016200ee84',
    };
    expected.forEach((quality, digest) {
      test('matches at quality $quality', () {
        final h = JpegHeader.build(quality: quality, width: 640, height: 360)!;
        expect(h.length, 605);
        expect(sha256.convert(h).toString(), digest);
      });
    });

    test('rejects unknown quality', () {
      expect(JpegHeader.build(quality: 42, width: 640, height: 360), isNull);
    });
  });

  group('VideoChannel', () {
    test('sends the hello until video starts', () {
      final c = VideoChannel(CameraFamily.bl608);
      expect(c.tick(0), [0xEF, 0x00, 0x04, 0x00]);
      expect(c.tick(50), isNull);
      expect(c.tick(101), [0xEF, 0x00, 0x04, 0x00]);
    });

    test('BL618 frames pass through unchanged', () {
      final c = VideoChannel(CameraFamily.bl618);
      final jpeg = body(3000);
      final out = [
        for (final f in fragmentFrame(seq: 1, body: jpeg))
          ...c.onDatagram(f, 0),
      ];
      expect(out.single, jpeg);
    });

    test('BL608 frames get a header and end marker', () {
      final c = VideoChannel(CameraFamily.bl608);
      final scan = body(2500);
      final out = [
        for (final f in fragmentFrame(
          seq: 1,
          body: scan,
          width: 640,
          height: 360,
        ))
          ...c.onDatagram(f, 0),
      ].single;
      expect(out.length, 605 + 2500 + 2);
      expect(out.sublist(0, 2), [0xFF, 0xD8]);
      expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
      expect(out.sublist(605, 605 + 2500), scan);
    });

    test('handles a frame that exactly fills its last fragment', () {
      final c = VideoChannel(CameraFamily.bl618);
      final out = [
        for (final f in fragmentFrame(seq: 1, body: body(2048)))
          ...c.onDatagram(f, 0),
      ];
      expect(out.single.length, 2048);
    });

    test('out-of-order frames are released in order', () {
      final c = VideoChannel(CameraFamily.bl608);
      final first = fragmentFrame(seq: 1, body: body(100));
      final second = fragmentFrame(seq: 2, body: body(200));
      expect(c.onDatagram(second.single, 0), isEmpty);
      final out = c.onDatagram(first.single, 1);
      expect(out.map((f) => f.length), [605 + 100 + 2, 605 + 200 + 2]);
    });

    test('BL618 skips a late frame once a newer one is complete', () {
      final c = VideoChannel(CameraFamily.bl618);
      final partial = fragmentFrame(seq: 1, body: body(2000));
      c.onDatagram(partial.first, 0);
      final out = c.onDatagram(fragmentFrame(seq: 2, body: body(50)).single, 1);
      expect(out.single.length, 50);
    });

    test('ack layout: magic, quality, camera and missing-fragment bitmap', () {
      final c = VideoChannel(CameraFamily.bl608);
      final frags = fragmentFrame(seq: 1, body: body(3000));
      c.onDatagram(frags[0], 0);
      c.onDatagram(frags[2], 0);
      final ack = c.tick(30)!;
      final view = ByteData.sublistView(ack);
      expect(ack.sublist(0, 2), [0xEF, 0x02]);
      expect(view.getUint16(2, Endian.little), ack.length);
      expect(ack.sublist(4, 8), [0x02, 0x02, 0x00, 0x01]);
      expect(ack.sublist(0x52, 0x57), [50, 75, 20, 45, 0]);

      var offset = 0x58;
      var found = false;
      for (var b = 0; b < ack[8]; b++) {
        final seq = view.getUint64(offset, Endian.little);
        final state = view.getUint32(offset + 8, Endian.little);
        if (seq == 1 && state == 0) {
          // Fragments 0 and 2 arrived, 1 is missing, unused bits are set.
          expect(view.getUint32(offset + 16, Endian.little), 0xFFFFFFFD);
          found = true;
        }
        offset += view.getUint32(offset + 12, Endian.little);
      }
      expect(found, isTrue);
      expect(offset, ack.length);
    });

    test('goes back to hello after 3 seconds of silence', () {
      final c = VideoChannel(CameraFamily.bl608);
      c.onDatagram(fragmentFrame(seq: 1, body: body(100)).single, 0);
      expect(c.streaming, isTrue);
      expect(c.tick(3001), [0xEF, 0x00, 0x04, 0x00]);
      expect(c.streaming, isFalse);
      // Sequence numbers restart cleanly after the reset.
      expect(c.onDatagram(fragmentFrame(seq: 1, body: body(9)).single, 3002), hasLength(1));
    });

    test('ignores malformed datagrams without throwing', () {
      final c = VideoChannel(CameraFamily.bl608);
      final good = fragmentFrame(seq: 1, body: body(3000))[0];
      Uint8List edit(int offset, int value) {
        final p = Uint8List.fromList(good);
        ByteData.sublistView(p).setUint32(offset, value, Endian.little);
        return p;
      }

      final bad = [
        Uint8List(0),
        Uint8List(3),
        Uint8List.fromList([0x93, 0x01, 0xFF, 0xFF]),
        good.sublist(0, 40),
        edit(0x20, 99), // index past the end
        edit(0x24, 0), // no fragments
        edit(0x24, 5000), // too many fragments
        edit(0x28, 0), // empty frame
        edit(0x28, 0x7FFFFFFF), // size larger than its fragments
        good.sublist(0, VideoChannel.headerSize + 10)..[2] = 0x42,
      ];
      for (final p in bad) {
        expect(c.onDatagram(p, 0), isEmpty);
      }
      expect(c.streaming, isFalse);
    });
  });

  group('over real UDP', () {
    Future<void> streamFrom(
      CameraFamily family, {
      required int dropEvery,
      required int frames,
    }) async {
      final car = await FakeCar.start(body(6000), dropEvery: dropEvery);
      final client = CarVideoClient(
        carAddress: InternetAddress.loopbackIPv4,
        portOverrides: {
          for (final f in CameraFamily.values)
            // The other family points at a closed port, as on a real car.
            f: f == family ? car.port : 9,
        },
        listenForBusy: false,
      );
      final got = <Uint8List>[];
      final done = Completer<void>();
      final sub = client.frames.listen((f) {
        got.add(f);
        if (got.length == frames && !done.isCompleted) done.complete();
      });
      await client.start();
      await done.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      await client.dispose();
      car.close();

      expect(car.helloCount, greaterThan(0));
      expect(car.ackCount, greaterThan(0));
      if (dropEvery > 0) expect(car.resent, greaterThan(0));
      final extra = family == CameraFamily.bl608 ? 605 + 2 : 0;
      expect(got.every((f) => f.length == 6000 + extra), isTrue);
    }

    test('BL608 clean link', () async {
      await streamFrom(CameraFamily.bl608, dropEvery: 0, frames: 10);
    });

    test('BL608 recovers lost fragments', () async {
      await streamFrom(CameraFamily.bl608, dropEvery: 4, frames: 10);
    });

    test('BL618 clean link', () async {
      await streamFrom(CameraFamily.bl618, dropEvery: 0, frames: 10);
    });

    test('BL618 recovers lost fragments', () async {
      await streamFrom(CameraFamily.bl618, dropEvery: 4, frames: 10);
    });
  });

  testWidgets('a rebuilt frame decodes as a real image', (tester) async {
    final scan = File('test/fixtures/scan_q50_64x32.bin').readAsBytesSync();
    final c = VideoChannel(CameraFamily.bl608);
    final jpeg = [
      for (final f in fragmentFrame(seq: 1, body: scan)) ...c.onDatagram(f, 0),
    ].single;
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 64);
      expect(frame.image.height, 32);
      frame.image.dispose();
      codec.dispose();
    });
  });

}
