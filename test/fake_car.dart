import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:car_cam/protocol/video_channel.dart';

/// Splits a frame into camera-format datagrams.
List<Uint8List> fragmentFrame({
  required int seq,
  required Uint8List body,
  int quality = 50,
  int width = 64,
  int height = 32,
  int peerAcked = 0,
}) {
  const size = VideoChannel.fragmentSize;
  final count = (body.length + size - 1) ~/ size;
  return [
    for (var i = 0; i < count; i++)
      () {
        final chunk = body.sublist(i * size, min((i + 1) * size, body.length));
        final length = VideoChannel.headerSize + chunk.length;
        final p = Uint8List(length);
        ByteData.sublistView(p)
          ..setUint8(0, 0x93)
          ..setUint8(1, 0x01)
          ..setUint16(2, length, Endian.little)
          ..setUint64(0x08, seq, Endian.little)
          ..setUint64(0x18, peerAcked, Endian.little)
          ..setUint32(0x20, i, Endian.little)
          ..setUint32(0x24, count, Endian.little)
          ..setUint32(0x28, body.length, Endian.little)
          ..setUint16(0x2C, width, Endian.little)
          ..setUint16(0x2E, height, Endian.little)
          ..setUint8(0x30, quality);
        p.setAll(VideoChannel.headerSize, chunk);
        return p;
      }(),
  ];
}

/// A pretend car on loopback: waits for hello, then streams frames, drops some
/// fragments, and resends only what the app's acks report as missing.
class FakeCar {
  FakeCar._(this._socket, this.frameBody, this.dropEvery);

  static Future<FakeCar> start(Uint8List body, {int dropEvery = 0}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final car = FakeCar._(socket, body, dropEvery);
    socket.listen((e) {
      if (e == RawSocketEvent.read) car._read();
    });
    return car;
  }

  final RawDatagramSocket _socket;
  final Uint8List frameBody;
  final int dropEvery;
  final _sent = <int, List<Uint8List>>{};
  InternetAddress? _peer;
  int? _peerPort;
  int _nextSeq = 1;
  int _counter = 0;
  int helloCount = 0;
  int ackCount = 0;
  int resent = 0;
  final ackPackets = <Uint8List>[];

  int get port => _socket.port;

  /// While true the car ignores everything, as if it were switched off.
  bool silent = false;

  void _read() {
    Datagram? d;
    while ((d = _socket.receive()) != null) {
      if (silent) continue;
      final p = d!.data;
      if (p.length == 4 && p[0] == 0xEF && p[1] == 0x00) {
        helloCount++;
        _peer = d.address;
        _peerPort = d.port;
        if (_nextSeq == 1) _sendNext();
      } else if (p.length >= 0x58 && p[0] == 0xEF && p[1] == 0x02) {
        ackCount++;
        ackPackets.add(p);
        _handleAck(p);
      }
    }
  }

  void _handleAck(Uint8List p) {
    final view = ByteData.sublistView(p);
    var offset = 0x58;
    for (var b = 0; b < p[8]; b++) {
      final seq = view.getUint64(offset, Endian.little);
      final state = view.getUint32(offset + 8, Endian.little);
      final length = view.getUint32(offset + 12, Endian.little);
      final frags = _sent[seq];
      if (state == 0 && frags != null) {
        for (var i = 0; i < frags.length; i++) {
          final byte = view.getUint8(offset + 16 + (i >> 3));
          if (byte & (1 << (i & 7)) == 0) {
            _socket.send(frags[i], _peer!, _peerPort!);
            resent++;
          }
        }
      } else if (state == 1 || state == 3) {
        final target = state == 1 ? seq + 1 : seq;
        if (target == _nextSeq) _sendNext();
      }
      offset += length;
    }
  }

  void _sendNext() {
    final seq = _nextSeq++;
    final frags = fragmentFrame(seq: seq, body: frameBody);
    _sent[seq] = frags;
    for (final f in frags) {
      _counter++;
      if (dropEvery > 0 && _counter % dropEvery == 0) continue;
      _socket.send(f, _peer!, _peerPort!);
    }
  }

  void close() => _socket.close();
}
