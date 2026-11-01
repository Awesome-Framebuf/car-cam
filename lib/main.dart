import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'protocol/car_video_client.dart';

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
  StreamSubscription<Uint8List>? _subscription;
  Timer? _statusTimer;
  ui.Image? _image;
  Uint8List? _pending;
  bool _decoding = false;
  DateTime? _lastFrameAt;

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
      _client.stop();
    }
  }

  void _onFrame(Uint8List jpeg) {
    _lastFrameAt = DateTime.now();
    // Only the newest frame matters: replace anything not yet decoded.
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

  bool get _isLive =>
      _lastFrameAt != null &&
      DateTime.now().difference(_lastFrameAt!) < _stalledAfter;

  String get _statusText {
    if (_client.carBusy) return 'Another phone is using the car';
    if (_image != null) return 'Reconnecting…';
    if (_client.packetsReceived > 0) return 'Starting video…';
    return "Connect this phone to the car's Wi-Fi";
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            RawImage(
              image: image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.low,
            ),
          if (!_isLive)
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    _statusText,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _subscription?.cancel();
    _client.dispose();
    _image?.dispose();
    super.dispose();
  }
}
