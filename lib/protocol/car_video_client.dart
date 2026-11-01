import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'video_channel.dart';

/// Connects to the car's camera on both known ports and emits JPEG frames.
class CarVideoClient {
  CarVideoClient({
    InternetAddress? carAddress,
    Map<CameraFamily, int>? portOverrides,
    this.listenForBusy = true,
  }) : _carAddress = carAddress ?? InternetAddress('192.168.169.1'),
       _portOverrides = portOverrides ?? const {};

  final InternetAddress _carAddress;
  final Map<CameraFamily, int> _portOverrides;
  final bool listenForBusy;

  final _frames = StreamController<Uint8List>.broadcast();
  final _sockets = <RawDatagramSocket>[];
  final _channels = <VideoChannel>[];
  final _clock = Stopwatch()..start();
  Timer? _timer;
  bool _running = false;

  /// True after the camera reports that another phone is using it.
  bool carBusy = false;

  Stream<Uint8List> get frames => _frames.stream;

  int get packetsReceived =>
      _channels.fold(0, (total, c) => total + c.packetsReceived);

  Future<void> start() async {
    if (_running) return;
    _running = true;
    carBusy = false;
    for (final family in CameraFamily.values) {
      final channel = VideoChannel(family);
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      final port = _portOverrides[family] ?? family.port;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = socket.receive()) != null) {
          for (final frame in channel.onDatagram(d!.data, _now)) {
            carBusy = false;
            _frames.add(frame);
          }
        }
      });
      _sockets.add(socket);
      _channels.add(channel);
      if (listenForBusy) await _bindBusy(family);
      _pumps.add((now) {
        final out = channel.tick(now);
        if (out == null) return;
        try {
          socket.send(out, _carAddress, port);
        } on SocketException {
          // Not on the car's network yet. The next tick tries again.
        }
      });
    }
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = _now;
      for (final pump in _pumps) {
        pump(now);
      }
    });
  }

  final _pumps = <void Function(int)>[];

  int get _now => _clock.elapsedMilliseconds;

  // Optional: without it the only symptom of a second phone is no video.
  Future<void> _bindBusy(CameraFamily family) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        family.busyPort,
        reuseAddress: true,
      );
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d != null &&
            d.data.length == 5 &&
            String.fromCharCodes(d.data, 0, 4) == 'busy') {
          carBusy = true;
        }
      });
      _sockets.add(socket);
    } on SocketException {
      // Port unavailable: everything except the busy message still works.
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _pumps.clear();
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
    _channels.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
