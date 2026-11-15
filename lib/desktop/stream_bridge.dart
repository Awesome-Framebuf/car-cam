import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Serves the live car video over HTTP as Motion-JPEG, so VLC, a browser, OBS
/// or ffmpeg can open it at `http://localhost:<port>/car.mjpg`.
///
/// Listens on this computer only unless [shareOnNetwork] is set.
class StreamBridge {
  StreamBridge({this.preferredPort = 8808, this.shareOnNetwork = false});

  final int preferredPort;
  final bool shareOnNetwork;
  static const _boundary = 'carcamframe';

  HttpServer? _server;
  Uint8List? _latest;
  final _clients = <_Client>{};

  int? get port => _server?.port;
  int get viewers => _clients.length;

  /// The address to paste into VLC, or null if not running.
  String? get url => port == null ? null : 'http://localhost:$port/car.mjpg';

  /// Starts on [preferredPort], or the next free one of the ten after it.
  Future<void> start() async {
    if (_server != null) return;
    final address = shareOnNetwork ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    SocketException? last;
    for (var p = preferredPort; p < preferredPort + 10; p++) {
      try {
        _server = await HttpServer.bind(address, p);
        break;
      } on SocketException catch (e) {
        last = e;
      }
    }
    if (_server == null) throw last!;
    _server!.listen(_handle, onError: (Object _) {});
  }

  void _handle(HttpRequest req) {
    final path = req.uri.path;
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    res.headers.set('Access-Control-Allow-Origin', '*');
    if (path == '/car.mjpg' || path == '/stream.mjpg') {
      res.bufferOutput = false;
      res.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/x-mixed-replace; boundary=$_boundary',
      );
      final client = _Client(res);
      _clients.add(client);
      res.done.whenComplete(() => _clients.remove(client)).ignore();
      // Send the headers now, so players connect before the next frame.
      client.start(_latest);
    } else if (path == '/car.jpg' || path == '/snapshot.jpg') {
      final jpeg = _latest;
      if (jpeg == null) {
        res.statusCode = HttpStatus.serviceUnavailable;
        res.write('No video yet\n');
      } else {
        res.headers.contentType = ContentType('image', 'jpeg');
        res.add(jpeg);
      }
      res.close();
    } else if (path == '/') {
      res.headers.contentType = ContentType.html;
      res.write(
        '<!doctype html><title>Car Cam</title>'
        '<body style="margin:0;background:#000">'
        '<img src="car.mjpg" style="width:100vw;height:100vh;object-fit:contain">',
      );
      res.close();
    } else {
      res.statusCode = HttpStatus.notFound;
      res.close();
    }
  }

  /// Sends a frame to every viewer. Viewers that haven't taken the last
  /// frame yet skip this one rather than fall behind.
  void addFrame(Uint8List jpeg) {
    _latest = jpeg;
    for (final c in _clients.toList()) {
      c.send(jpeg);
    }
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

class _Client {
  _Client(this.res);

  final HttpResponse res;
  bool _busy = false;
  bool _dead = false;

  void start(Uint8List? first) {
    _busy = true;
    // The opening boundary makes the headers go out now. Each part then ends
    // with the next boundary.
    res.write('--${StreamBridge._boundary}\r\n');
    res.flush().then((_) {
      _busy = false;
      if (first != null) send(first);
    }, onError: (Object _) {
      _dead = true;
    });
  }

  void send(Uint8List jpeg) {
    if (_busy || _dead) return;
    _busy = true;
    try {
      res.write(
        'Content-Type: image/jpeg\r\n'
        'Content-Length: ${jpeg.length}\r\n\r\n',
      );
      res.add(jpeg);
      res.write('\r\n--${StreamBridge._boundary}\r\n');
      res.flush().then((_) => _busy = false, onError: (Object _) => _dead = true);
    } catch (_) {
      _dead = true;
    }
  }

  void close() {
    _dead = true;
    res.close().ignore();
  }
}
