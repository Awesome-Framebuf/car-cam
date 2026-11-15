import 'dart:io';
import 'dart:typed_data';

/// Writes JPEG frames straight into a Motion-JPEG AVI file, which VLC, mpv,
/// ffmpeg and Windows players open without any re-encoding.
///
/// Frames arrive at whatever rate the car manages, so the file's frame rate is
/// set on [close] to the average over the recording.
class AviWriter {
  AviWriter._(this.file, this._raf, this.width, this.height);

  final File file;
  final RandomAccessFile _raf;
  final int width;
  final int height;
  final _index = BytesBuilder(copy: false);
  final _clock = Stopwatch();
  int _frames = 0;
  int _moviStart = 0;
  int _largest = 0;
  bool _closed = false;

  int get frames => _frames;
  Duration get elapsed => _clock.elapsed;

  // Offsets of the fields patched on close.
  static const _riffSize = 4;
  static const _avihMicroSecPerFrame = 32;
  static const _avihMaxBytesPerSec = 36;
  static const _avihTotalFrames = 48;
  static const _avihSuggestedBuffer = 60;
  static const _strhScale = 128;
  static const _strhRate = 132;
  static const _strhLength = 140;
  static const _strhSuggestedBuffer = 144;
  static const _moviListSize = 216;
  static const _headerSize = 224;

  static Future<AviWriter> create(File file, {required int width, required int height}) async {
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    final w = AviWriter._(file, raf, width, height);
    await raf.writeFrom(w._header());
    w._moviStart = _headerSize - 4; // the 'movi' fourcc
    w._clock.start();
    return w;
  }

  Uint8List _header() {
    final b = ByteData(_headerSize);
    var o = 0;
    void tag(String s) {
      for (final c in s.codeUnits) {
        b.setUint8(o++, c);
      }
    }

    void u32(int v) {
      b.setUint32(o, v, Endian.little);
      o += 4;
    }

    void u16(int v) {
      b.setUint16(o, v, Endian.little);
      o += 2;
    }

    tag('RIFF'); u32(0); tag('AVI ');
    tag('LIST'); u32(192); tag('hdrl');
    tag('avih'); u32(56);
    u32(40000); // microseconds per frame, patched
    u32(0); // max bytes per second, patched
    u32(0); // padding granularity
    u32(0x10); // AVIF_HASINDEX
    u32(0); // total frames, patched
    u32(0); // initial frames
    u32(1); // streams
    u32(0); // suggested buffer, patched
    u32(width); u32(height);
    u32(0); u32(0); u32(0); u32(0);
    tag('LIST'); u32(116); tag('strl');
    tag('strh'); u32(56);
    tag('vids'); tag('MJPG');
    u32(0); u16(0); u16(0); u32(0);
    u32(1000); // scale, patched
    u32(25000); // rate, patched
    u32(0); // start
    u32(0); // length in frames, patched
    u32(0); // suggested buffer, patched
    u32(0xFFFFFFFF); // quality: default
    u32(0); // sample size
    u16(0); u16(0); u16(width); u16(height);
    tag('strf'); u32(40);
    u32(40); u32(width); u32(height); u16(1); u16(24);
    tag('MJPG'); u32(width * height * 3);
    u32(0); u32(0); u32(0); u32(0);
    tag('LIST'); u32(4); tag('movi');
    assert(o == _headerSize);
    return b.buffer.asUint8List();
  }

  Future<void> addFrame(Uint8List jpeg) async {
    if (_closed) return;
    final pad = jpeg.length.isOdd ? 1 : 0;
    final pos = await _raf.position();
    final chunk = ByteData(8)
      ..setUint32(0, 0x63643030, Endian.little) // '00dc'
      ..setUint32(4, jpeg.length, Endian.little);
    await _raf.writeFrom(chunk.buffer.asUint8List());
    await _raf.writeFrom(jpeg);
    if (pad == 1) await _raf.writeByte(0);
    final entry = ByteData(16)
      ..setUint32(0, 0x63643030, Endian.little)
      ..setUint32(4, 0x10, Endian.little) // AVIIF_KEYFRAME
      ..setUint32(8, pos - _moviStart, Endian.little)
      ..setUint32(12, jpeg.length, Endian.little);
    _index.add(entry.buffer.asUint8List());
    if (jpeg.length > _largest) _largest = jpeg.length;
    _frames++;
  }

  /// Finishes the file. Returns the number of frames written.
  Future<int> close() async {
    if (_closed) return _frames;
    _closed = true;
    _clock.stop();
    final moviEnd = await _raf.position();
    final idx = _index.takeBytes();
    final idxHeader = ByteData(8)
      ..setUint32(0, 0x31786469, Endian.little) // 'idx1'
      ..setUint32(4, idx.length, Endian.little);
    await _raf.writeFrom(idxHeader.buffer.asUint8List());
    await _raf.writeFrom(idx);
    final end = await _raf.position();

    final seconds = _clock.elapsedMicroseconds / 1e6;
    final fps = _frames > 1 && seconds > 0 ? _frames / seconds : 25.0;
    final rate = (fps * 1000).round().clamp(1000, 120000);
    final usPerFrame = (1e9 / rate).round();
    final bytesPerSec = seconds > 0 ? ((moviEnd - _headerSize) / seconds).round() : 0;

    Future<void> put(int at, int v) async {
      await _raf.setPosition(at);
      final d = ByteData(4)..setUint32(0, v, Endian.little);
      await _raf.writeFrom(d.buffer.asUint8List());
    }

    await put(_riffSize, end - 8);
    await put(_avihMicroSecPerFrame, usPerFrame);
    await put(_avihMaxBytesPerSec, bytesPerSec);
    await put(_avihTotalFrames, _frames);
    await put(_avihSuggestedBuffer, _largest + 8);
    await put(_strhScale, 1000);
    await put(_strhRate, rate);
    await put(_strhLength, _frames);
    await put(_strhSuggestedBuffer, _largest + 8);
    await put(_moviListSize, moviEnd - (_moviListSize + 4));
    await _raf.close();
    return _frames;
  }
}
