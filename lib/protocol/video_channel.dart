import 'dart:typed_data';

import 'jpeg_header.dart';

/// The two camera families the car may use. See docs/PROTOCOL.md.
enum CameraFamily {
  /// Port 8800. Frames arrive without a JPEG header or end marker.
  bl608(
    port: 8800,
    busyPort: 10010,
    maxFragments: 1024,
    helloEveryMs: 101,
    ackEveryMs: 25,
    quality: [50, 75, 20, 45],
  ),

  /// Port 8801. Frames arrive as complete JPEG files.
  bl618(
    port: 8801,
    busyPort: 10011,
    maxFragments: 512,
    helloEveryMs: 201,
    ackEveryMs: 51,
    quality: [25, 50, 8, 24],
  );

  const CameraFamily({
    required this.port,
    required this.busyPort,
    required this.maxFragments,
    required this.helloEveryMs,
    required this.ackEveryMs,
    required this.quality,
  });

  final int port;
  final int busyPort;
  final int maxFragments;
  final int helloEveryMs;
  final int ackEveryMs;

  /// Quality 1, quality 2, threshold 1 and threshold 2, as sent in each ack.
  final List<int> quality;
}

enum _SlotState { empty, receiving, complete, delivered, skipped }

class _Slot {
  _Slot(int bitmapBytes) : bitmap = Uint8List(bitmapBytes);

  _SlotState state = _SlotState.empty;
  int seq = 0;
  int fragments = 0;
  int size = 0;
  int width = 0;
  int height = 0;
  int quality = 0;
  Uint8List? data;
  final Uint8List bitmap;

  void markReceived(int index) => bitmap[index >> 3] |= 1 << (index & 7);

  bool get isComplete {
    for (var i = 0; i < fragments; i++) {
      if (bitmap[i >> 3] & (1 << (i & 7)) == 0) return false;
    }
    return true;
  }
}

/// Protocol state for one camera family. Holds no sockets or timers: the
/// caller passes datagrams and the current time in, which keeps it testable.
class VideoChannel {
  VideoChannel(this.family) {
    _reset();
  }

  static const fragmentSize = 1024;
  static const headerSize = 0x38;
  static const _reconnectAfterMs = 3001;
  static const _hello = [0xEF, 0x00, 0x04, 0x00];
  static const _ackHeaderSize = 0x58;
  static const _ackMagic = [0x02, 0x02, 0x00, 0x01];
  static const _mainCamera = 0;

  final CameraFamily family;

  late List<_Slot> _slots;
  bool _streaming = false;
  int _peerAcked = 0;
  int _maxSeq = 0;
  int _nextSeq = 1;
  int _nextIndex = 0;
  int _currentSlot = 0;
  int? _lastFragmentMs;
  int? _lastHelloMs;
  int? _lastAckMs;

  int packetsReceived = 0;
  int framesDelivered = 0;

  bool get streaming => _streaming;

  void _reset() {
    final bitmapBytes = family.maxFragments ~/ 8;
    _slots = List.generate(4, (_) => _Slot(bitmapBytes));
    _streaming = false;
    _peerAcked = 0;
    _maxSeq = 0;
    _nextSeq = 1;
    _nextIndex = 0;
    _currentSlot = 0;
    _lastFragmentMs = null;
    _lastAckMs = null;
  }

  /// Handles one received datagram and returns any frames now ready, in order.
  List<Uint8List> onDatagram(Uint8List p, int nowMs) {
    if (p.length < 4 || p[0] != 0x93) return const [];
    final view = ByteData.sublistView(p);
    if (view.getUint16(2, Endian.little) != p.length) return const [];
    packetsReceived++;
    if (p[1] != 0x01 || p.length < headerSize) return const [];

    final seq = view.getUint64(0x08, Endian.little);
    final index = view.getUint32(0x20, Endian.little);
    final fragments = view.getUint32(0x24, Endian.little);
    final size = view.getUint32(0x28, Endian.little);
    if (seq < 1 ||
        fragments == 0 ||
        index >= fragments ||
        fragments > family.maxFragments ||
        size == 0 ||
        size > fragments * fragmentSize ||
        size <= (fragments - 1) * fragmentSize) {
      return const [];
    }

    _peerAcked = view.getUint64(0x18, Endian.little);
    if (_maxSeq < seq) _maxSeq = seq;
    final slotIndex = (seq + 3) & 3;
    _currentSlot = slotIndex;
    final slot = _slots[slotIndex];

    final reusable =
        slot.state == _SlotState.empty ||
        slot.state == _SlotState.delivered ||
        slot.state == _SlotState.skipped;
    if (reusable && (slot.seq == seq - 4 || (slot.seq == 0 && seq < 5))) {
      _streaming = true;
      _lastFragmentMs = nowMs;
      slot
        ..state = _SlotState.receiving
        ..seq = seq
        ..fragments = fragments
        ..size = size
        ..width = view.getUint16(0x2C, Endian.little)
        ..height = view.getUint16(0x2E, Endian.little)
        ..quality = p[0x30]
        ..data = Uint8List(size);
      slot.bitmap.fillRange(0, slot.bitmap.length, 0);
    } else if (slot.state == _SlotState.receiving && slot.seq == seq) {
      _lastFragmentMs = nowMs;
    } else {
      return const [];
    }

    if (!_store(slot, p, index)) return const [];
    slot.markReceived(index);
    if (!slot.isComplete) return const [];
    slot.state = _SlotState.complete;
    return _collectReadyFrames();
  }

  bool _store(_Slot slot, Uint8List p, int index) {
    final isLast = index == slot.fragments - 1;
    final remainder = slot.size & (fragmentSize - 1);
    final length = isLast && remainder != 0 ? remainder : fragmentSize;
    if (p.length - headerSize < length) return false;
    slot.data!.setRange(
      index * fragmentSize,
      index * fragmentSize + length,
      p,
      headerSize,
    );
    return true;
  }

  List<Uint8List> _collectReadyFrames() {
    final out = <Uint8List>[];
    final start = _nextIndex;
    for (var k = 0; k < 4; k++) {
      final slot = _slots[(start + k) % 4];
      if (slot.state == _SlotState.complete && slot.seq == _nextSeq) {
        _deliver(slot, out);
      }
    }
    // BL618 doesn't wait for a late frame once a newer one is complete.
    if (out.isEmpty && family == CameraFamily.bl618) {
      final base = _nextIndex;
      var found = false;
      for (var k = 0; k < 4; k++) {
        final slot = _slots[(base + k) % 4];
        if (slot.state == _SlotState.receiving &&
            slot.seq == _nextSeq &&
            !found) {
          slot.state = _SlotState.skipped;
          _advance();
        } else if (slot.state == _SlotState.complete && slot.seq == _nextSeq) {
          found = true;
          _deliver(slot, out);
        }
      }
    }
    return out;
  }

  void _deliver(_Slot slot, List<Uint8List> out) {
    final frame = _finishFrame(slot);
    slot
      ..state = _SlotState.delivered
      ..data = null;
    _advance();
    if (frame != null) {
      framesDelivered++;
      out.add(frame);
    }
  }

  void _advance() {
    _nextSeq++;
    _nextIndex = (_nextIndex + 1) % 4;
  }

  Uint8List? _finishFrame(_Slot slot) {
    if (family == CameraFamily.bl618) return slot.data;
    final header = JpegHeader.build(
      quality: slot.quality,
      width: slot.width,
      height: slot.height,
    );
    if (header == null) return null;
    final jpeg = Uint8List(header.length + slot.size + 2)
      ..setAll(0, header)
      ..setAll(header.length, slot.data!);
    jpeg[jpeg.length - 2] = 0xFF;
    jpeg[jpeg.length - 1] = 0xD9;
    return jpeg;
  }

  /// Runs periodic work and returns the datagram to send now, if any.
  Uint8List? tick(int nowMs) {
    if (!_streaming) {
      final last = _lastHelloMs;
      if (last == null || nowMs - last >= family.helloEveryMs) {
        _lastHelloMs = nowMs;
        return Uint8List.fromList(_hello);
      }
      return null;
    }

    final sinceFragment = nowMs - _lastFragmentMs!;
    if (sinceFragment >= _reconnectAfterMs) {
      _reset();
      _lastHelloMs = nowMs;
      return Uint8List.fromList(_hello);
    }

    final lastAck = _lastAckMs;
    if (lastAck != null && nowMs - lastAck < family.ackEveryMs) return null;

    if (family == CameraFamily.bl618) {
      if (sinceFragment <= 25) return null;
      _lastAckMs = nowMs;
      return _buildAck(_noSlot);
    }
    _lastAckMs = nowMs;
    return _buildAck(sinceFragment >= 20 ? _noSlot : _currentSlot);
  }

  static const _noSlot = -2;

  /// Reports the state of each frame slot so the camera can resend what's
  /// missing. [skip] is a slot still being received, left out of the report.
  Uint8List? _buildAck(int skip) {
    final blocks = BytesBuilder(copy: false);
    var count = 0;
    var allDone = true;

    void addBlock(int seq, int state, [Uint8List? bitmap]) {
      final data = ByteData(16)
        ..setUint64(0, seq, Endian.little)
        ..setUint32(8, state, Endian.little)
        ..setUint32(12, 16 + (bitmap?.length ?? 0), Endian.little);
      blocks.add(data.buffer.asUint8List());
      if (bitmap != null) blocks.add(bitmap);
      count++;
      if (state != 1 && state != 2) allDone = false;
    }

    for (var i = 0; i < 4; i++) {
      if (i == skip) continue;
      final slot = _slots[i];
      final used = slot.state != _SlotState.empty;
      if (_maxSeq - slot.seq < 5 && (used || _maxSeq <= i + 1)) {
        if (_peerAcked < slot.seq && used) {
          final state = switch (slot.state) {
            _SlotState.receiving => 0,
            _SlotState.skipped => 2,
            _ => 1,
          };
          final words = (slot.fragments + 31) ~/ 32;
          addBlock(slot.seq, state, _ackBitmap(slot, words * 4));
        }
      } else {
        addBlock(slot.seq == 0 ? i + 1 : slot.seq + 4, 3);
      }
    }
    if (skip == _noSlot && allDone) addBlock(_nextSeq, 3);
    if (family == CameraFamily.bl618 && count == 0) return null;

    final body = blocks.toBytes();
    final length = _ackHeaderSize + body.length;
    final out = Uint8List(length)
      ..[0] = 0xEF
      ..[1] = 0x02
      ..[2] = length & 0xFF
      ..[3] = (length >> 8) & 0xFF
      ..setAll(4, _ackMagic)
      ..[8] = count
      ..setAll(0x52, family.quality)
      ..[0x56] = _mainCamera
      ..setAll(_ackHeaderSize, body);
    return out;
  }

  /// Bits past the frame's fragment count are reported as set.
  Uint8List _ackBitmap(_Slot slot, int bytes) {
    final out = Uint8List(bytes);
    for (var i = 0; i < bytes * 8; i++) {
      final have = i >= slot.fragments || slot.bitmap[i >> 3] & (1 << (i & 7)) != 0;
      if (have) out[i >> 3] |= 1 << (i & 7);
    }
    return out;
  }
}
