import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/car_video_client.dart';
import 'avi_writer.dart';
import 'jpeg_size.dart';
import 'stream_bridge.dart';

/// Where photos and videos go: `~/Pictures/Car Cam` and `~/Videos/Car Cam`.
class MediaFolders {
  const MediaFolders(this.photos, this.videos);

  final Directory photos;
  final Directory videos;

  factory MediaFolders.defaults() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    final sep = Platform.pathSeparator;
    String xdg(String key, String fallback) {
      // Honour localised folder names from user-dirs.dirs on Linux.
      try {
        final f = File('$home/.config/user-dirs.dirs');
        final m = RegExp('^$key="([^"]+)"', multiLine: true).firstMatch(f.readAsStringSync());
        if (m != null) return m.group(1)!.replaceAll(r'$HOME', home);
      } catch (_) {}
      return '$home$sep$fallback';
    }

    return MediaFolders(
      Directory('${xdg('XDG_PICTURES_DIR', 'Pictures')}${sep}Car Cam'),
      Directory('${xdg('XDG_VIDEOS_DIR', 'Videos')}${sep}Car Cam'),
    );
  }
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
}

String safeFileName(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();

/// The video from one car, on one adapter.
///
/// The client is pinned to the adapter, because every car is 192.168.169.1.
/// One session per adapter lets several cars run side by side.
class CarSession {
  CarSession({
    required this.label,
    this.device,
    this.localAddress,
    this.bridge,
    MediaFolders? folders,
    CarVideoClient? client,
  }) : folders = folders ?? MediaFolders.defaults(),
       client = client ??
           CarVideoClient(
             bindDevice: device,
             localAddress: localAddress,
             // The busy ports are fixed numbers, so only one session can
             // listen. Only the unpinned session tries.
             listenForBusy: device == null,
           );

  /// Name shown for the car.
  String label;

  /// Adapter the car is on, or null for the normal route.
  final String? device;
  final InternetAddress? localAddress;

  final CarVideoClient client;
  final StreamBridge? bridge;
  final MediaFolders folders;

  final _frames = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  Uint8List? latest;
  DateTime? lastFrameAt;
  int framesReceived = 0;
  AviWriter? _recorder;
  Future<void> _recordQueue = Future.value();

  Stream<Uint8List> get frames => _frames.stream;
  bool get isRecording => _recorder != null;
  Duration get recordingElapsed => _recorder?.elapsed ?? Duration.zero;

  bool get isLive =>
      lastFrameAt != null &&
      DateTime.now().difference(lastFrameAt!) < const Duration(seconds: 2);

  Future<void> start() async {
    _sub ??= client.frames.listen(_onFrame);
    await client.start();
  }

  void _onFrame(Uint8List jpeg) {
    latest = jpeg;
    lastFrameAt = DateTime.now();
    framesReceived++;
    bridge?.addFrame(jpeg);
    final rec = _recorder;
    if (rec != null) {
      // Written in order; a slow disk delays frames but never reorders them.
      _recordQueue = _recordQueue.then((_) => rec.addFrame(jpeg)).catchError((Object _) {});
    }
    _frames.add(jpeg);
  }

  /// Saves the newest frame. Returns the file, or null with no video yet.
  Future<File?> takePhoto() async {
    final jpeg = latest;
    if (jpeg == null) return null;
    await folders.photos.create(recursive: true);
    final f = File(
      '${folders.photos.path}${Platform.pathSeparator}'
      '${safeFileName(label)} ${_stamp(DateTime.now())}.jpg',
    );
    await f.writeAsBytes(jpeg, flush: true);
    return f;
  }

  Future<void> startRecording() async {
    if (_recorder != null) return;
    final size = latest == null ? null : jpegSize(latest!);
    final f = File(
      '${folders.videos.path}${Platform.pathSeparator}'
      '${safeFileName(label)} ${_stamp(DateTime.now())}.avi',
    );
    _recorder = await AviWriter.create(
      f,
      width: size?.$1 ?? 640,
      height: size?.$2 ?? 360,
    );
  }

  /// Finishes the video. Returns the file and its frame count.
  Future<(File, int)?> stopRecording() async {
    final rec = _recorder;
    if (rec == null) return null;
    _recorder = null;
    await _recordQueue;
    final frames = await rec.close();
    if (frames == 0) {
      await rec.file.delete().catchError((Object _) => rec.file);
    }
    return (rec.file, frames);
  }

  Future<void> stop() async {
    await stopRecording();
    await client.stop();
    lastFrameAt = null;
  }

  Future<void> dispose() async {
    await stop();
    await _sub?.cancel();
    await client.dispose();
    await _frames.close();
  }
}
