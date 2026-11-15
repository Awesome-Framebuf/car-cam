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
    this.bindDevice,
    this.localAddress,
  }) : _carAddress = carAddress ?? InternetAddress('192.168.169.1'),
       _portOverrides = portOverrides ?? const {};

  final InternetAddress _carAddress;
  final Map<CameraFamily, int> _portOverrides;
  final bool listenForBusy;

  /// Linux network interface to send and receive on, such as `wlan1`.
  ///
  /// Every car is at the same address, so with several cars on several Wi-Fi
  /// adapters each client must be pinned to its own adapter. Null uses the
  /// normal route.
  final String? bindDevice;

  /// Local address to bind to instead of any address. On Windows this is how
  /// a client is pinned to one adapter.
  final InternetAddress? localAddress;

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
        localAddress ?? InternetAddress.anyIPv4,
        0,
      );
      if (bindDevice != null) _bindToDevice(socket, bindDevice!);
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

  // SO_BINDTODEVICE. Allowed for ordinary users since Linux 5.7.
  static void _bindToDevice(RawDatagramSocket socket, String device) {
    const solSocket = 1, soBindToDevice = 25;
    socket.setRawOption(
      RawSocketOption(
        solSocket,
        soBindToDevice,
        Uint8List.fromList([...device.codeUnits, 0]),
      ),
    );
  }

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
