import 'package:flutter/services.dart';

/// Asks the native window to go full screen or back.
///
/// The runner answers on the `car_cam/window` channel: Linux in
/// `linux/runner/my_application.cc`, Windows in
/// `windows/runner/flutter_window.cpp`. Where no runner answers, the app still
/// hides its controls, so the video fills the window instead of the screen.
class WindowControl {
  const WindowControl();

  static const _channel = MethodChannel('car_cam/window');

  /// Returns false when the platform can't make the window full screen.
  Future<bool> setFullScreen(bool on) async {
    try {
      await _channel.invokeMethod<void>('setFullScreen', on);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
