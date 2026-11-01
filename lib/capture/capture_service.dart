import 'package:flutter/services.dart';

/// Thrown when the user has refused access to the phone's photo library.
class CapturePermissionDenied implements Exception {}

/// Talks to the native code that saves photos and encodes videos.
class CaptureService {
  const CaptureService();

  static const _channel = MethodChannel('car_cam/capture');

  Future<void> savePhoto(Uint8List jpeg) => _guard(() => _channel.invokeMethod('savePhoto', jpeg));

  Future<void> startRecording() => _guard(() => _channel.invokeMethod('startRecording'));

  /// Queues a frame. Frames may be dropped if the phone can't keep up.
  void addFrame(Uint8List jpeg, int ptsMs) {
    _channel
        .invokeMethod('frame', {'jpeg': jpeg, 'ptsMs': ptsMs})
        .catchError((Object _) => null);
  }

  /// Finishes the video, saves it to the gallery and returns its frame count.
  Future<int> stopRecording() async {
    final result = await _guard(
      () => _channel.invokeMapMethod<String, Object?>('stopRecording'),
    );
    return (result?['frames'] as int?) ?? 0;
  }

  Future<void> openWifiSettings() => _channel.invokeMethod('openWifiSettings');

  Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') throw CapturePermissionDenied();
      rethrow;
    }
  }
}
