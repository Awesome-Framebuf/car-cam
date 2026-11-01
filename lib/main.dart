import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'capture/capture_service.dart';
import 'protocol/car_video_client.dart';
import 'ui/camera_view.dart';
import 'ui/connect_guide.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(
    const MaterialApp(
      title: 'Car Cam',
      debugShowCheckedModeBanner: false,
      home: VideoScreen(),
    ),
  );
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> with WidgetsBindingObserver {
  static const _stalledAfter = Duration(seconds: 2);

  final _client = CarVideoClient();
  final _capture = const CaptureService();
  final _recordingClock = Stopwatch();
  StreamSubscription<Uint8List>? _subscription;
  Timer? _statusTimer;
  ui.Image? _image;
  Uint8List? _latestJpeg;
  Uint8List? _pending;
  bool _decoding = false;
  DateTime? _lastFrameAt;
  bool _isRecording = false;
  bool _isChangingRecording = false;
  bool _isFlashing = false;
  bool _showGuide = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _client.frames.listen(_onFrame);
    _client.start();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _client.start();
    } else if (state == AppLifecycleState.paused) {
      // Save what's been recorded rather than lose it in the background.
      if (_isRecording) _toggleRecording();
      _client.stop();
    }
  }

  void _onFrame(Uint8List jpeg) {
    _lastFrameAt = DateTime.now();
    _latestJpeg = jpeg;
    if (_isRecording) {
      // Every frame goes to the video, even ones the screen skips.
      _capture.addFrame(jpeg, _recordingClock.elapsedMilliseconds);
    }
    // Only the newest frame matters on screen: replace anything not yet decoded.
    _pending = jpeg;
    if (!_decoding) _decodeLatest();
  }

  Future<void> _decodeLatest() async {
    _decoding = true;
    while (_pending != null && mounted) {
      final jpeg = _pending!;
      _pending = null;
      try {
        final codec = await ui.instantiateImageCodec(jpeg);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) {
          frame.image.dispose();
          break;
        }
        final old = _image;
        setState(() => _image = frame.image);
        old?.dispose();
      } catch (_) {
        // A damaged frame: keep showing the last good one.
      }
    }
    _decoding = false;
  }

  Future<void> _takePhoto() async {
    final jpeg = _latestJpeg;
    if (jpeg == null) return;
    setState(() => _isFlashing = true);
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _isFlashing = false);
    });
    try {
      await _capture.savePhoto(jpeg);
      _showMessage('Photo saved');
    } catch (e) {
      _showSaveError(e, 'photo');
    }
  }

  Future<void> _toggleRecording() async {
    if (_isChangingRecording) return;
    _isChangingRecording = true;
    try {
      if (_isRecording) {
        setState(() => _isRecording = false);
        _recordingClock.stop();
        await _capture.stopRecording();
        _showMessage('Video saved');
      } else {
        await _capture.startRecording();
        _recordingClock
          ..reset()
          ..start();
        setState(() => _isRecording = true);
      }
    } catch (e) {
      _showSaveError(e, 'video');
    } finally {
      _isChangingRecording = false;
    }
  }

  void _showMessage(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: action,
          behavior: SnackBarBehavior.floating,
          width: 360,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _showSaveError(Object error, String what) {
    if (error is CapturePermissionDenied) {
      _showMessage(
        'Allow access to your photos to save this $what',
        action: SnackBarAction(
          label: 'Settings',
          onPressed: _capture.openAppSettings,
        ),
      );
    } else {
      _showMessage("Couldn't save the $what");
    }
  }

  bool get _isLive =>
      _lastFrameAt != null &&
      DateTime.now().difference(_lastFrameAt!) < _stalledAfter;

  String get _statusText {
    if (_client.carBusy) return 'Another phone is using the car';
    if (_image != null) return 'Reconnecting…';
    return 'Starting video…';
  }

  bool get _isWaitingForCar =>
      _image == null && _client.packetsReceived == 0 && !_client.carBusy;

  void _closeGuide() {
    setState(() => _showGuide = false);
  }

  @override
  Widget build(BuildContext context) {
    final guide = _showGuide || _isWaitingForCar;
    return Scaffold(
      backgroundColor: Colors.black,
      body: guide
          ? ConnectGuide(
              onOpenSettings: _capture.openWifiSettings,
              onClose: _showGuide ? _closeGuide : null,
            )
          : CameraView(
              image: _image,
              isLive: _isLive,
              statusText: _statusText,
              isRecording: _isRecording,
              recordingElapsed: _recordingClock.elapsed,
              isFlashing: _isFlashing,
              onTakePhoto: _takePhoto,
              onToggleRecording: _toggleRecording,
              onHelp: () => setState(() => _showGuide = true),
            ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _subscription?.cancel();
    if (_isRecording) _capture.stopRecording().catchError((Object _) => 0);
    _client.dispose();
    _image?.dispose();
    super.dispose();
  }
}
