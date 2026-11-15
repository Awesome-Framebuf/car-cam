import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/camera_view.dart';
import 'car_network.dart';
import 'car_session.dart';
import 'car_store.dart';
import 'stream_bridge.dart';
import 'window_control.dart';

/// Makes the session for a car. Tests pass one that points at a simulated car.
typedef SessionFactory = CarSession Function({
  required String label,
  String? device,
  StreamBridge? bridge,
});

class DesktopApp extends StatelessWidget {
  const DesktopApp({super.key, this.network, this.store, this.bridge, this.sessionFactory});

  final CarNetwork? network;
  final CarStore? store;
  final StreamBridge? bridge;
  final SessionFactory? sessionFactory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Cam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
      ),
      home: DesktopHome(
        network: network,
        store: store,
        bridge: bridge,
        sessionFactory: sessionFactory,
      ),
    );
  }
}

class DesktopHome extends StatefulWidget {
  const DesktopHome({super.key, this.network, this.store, this.bridge, this.sessionFactory});

  final CarNetwork? network;
  final CarStore? store;
  final StreamBridge? bridge;
  final SessionFactory? sessionFactory;

  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

/// One row in the car list: a remembered car, a car in range, or both.
class _CarEntry {
  _CarEntry(this.ssid, {this.saved});
  final String ssid;
  SavedCar? saved;
  ScannedCar? scanned;
  String get name => saved?.name ?? ssid;
}

class _DesktopHomeState extends State<DesktopHome> {
  late final CarNetwork _net = widget.network ?? CarNetwork.forPlatform();
  late final CarStore _store = widget.store ?? CarStore(CarStore.defaultFile());
  late final StreamBridge _bridge = widget.bridge ?? StreamBridge();
  late final AppLifecycleListener _lifecycle;

  List<WifiAdapter> _adapters = const [];
  String? _device;
  List<ScannedCar> _scanned = const [];
  bool _scanning = false;
  String? _joining;
  String? _error;

  /// The car being shown. Kept per adapter so more can be added later.
  CarSession? _session;
  StreamSubscription<Uint8List>? _sub;
  ui.Image? _image;
  Uint8List? _pending;
  bool _decoding = false;
  bool _flash = false;
  bool _changingRecording = false;
  Timer? _ticker;
  int _refreshCount = 0;

  /// Video only, filling the screen. Esc, F11 or a double click leaves it.
  bool _fullScreen = false;
  final WindowControl _window = const WindowControl();

  bool get _managed => _net is! UnsupportedCarNetwork;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
    HardwareKeyboard.instance.addHandler(_onKey);
    _init();
  }

  Future<void> _init() async {
    await _store.load();
    try {
      await _bridge.start();
    } catch (e) {
      _error = 'Stream for VLC unavailable: $e';
    }
    await _refreshAdapters(pickDevice: true);
    if (!_managed) {
      // No automatic joining here: show whatever car the computer is on.
      await _openSession(label: 'Car', device: null);
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {});
      if (++_refreshCount % 10 == 0) _refreshAdapters();
    });
    if (_device != null) _scan();
  }

  Future<ui.AppExitResponse> _onExit() async {
    await _closeSession();
    await _bridge.stop();
    return ui.AppExitResponse.exit;
  }

  Future<void> _refreshAdapters({bool pickDevice = false}) async {
    if (!_managed) return;
    try {
      final list = await _net.adapters();
      if (!mounted) return;
      setState(() {
        _adapters = list;
        final current = list.where((a) => a.device == _device);
        if (pickDevice || current.isEmpty || !current.first.isFree) {
          final onCar = list.where((a) => a.onCar);
          final free = list.where((a) => a.isFree);
          _device = onCar.isNotEmpty
              ? onCar.first.device
              : free.isNotEmpty
              ? free.first.device
              : null;
        }
      });
      // Already on a car (joined earlier or by hand): show it.
      final adapter = list.where((a) => a.device == _device && a.onCar);
      if (_session == null && adapter.isNotEmpty && _joining == null) {
        final a = adapter.first;
        await _store.remember(a.ssid!, a.device);
        await _openSession(label: _store.find(a.ssid!)!.name, device: a.device, ssid: a.ssid);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _scan() async {
    final device = _device;
    if (device == null || _scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final found = await _net.scan(device);
      if (mounted) setState(() => _scanned = found);
    } catch (e) {
      if (mounted) setState(() => _error = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  String? _sessionSsid;

  Future<void> _openSession({required String label, String? device, String? ssid}) async {
    await _closeSession();
    final s =
        widget.sessionFactory?.call(label: label, device: device, bridge: _bridge) ??
        CarSession(label: label, device: device, bridge: _bridge);
    _session = s;
    _sessionSsid = ssid;
    _sub = s.frames.listen(_onFrame);
    await s.start();
    if (mounted) setState(() {});
  }

  Future<void> _closeSession() async {
    final s = _session;
    if (s == null) return;
    _session = null;
    _sessionSsid = null;
    await _sub?.cancel();
    _sub = null;
    final saved = await s.stopRecording();
    if (saved != null && saved.$2 > 0) _toast('Video saved: ${saved.$1.path}');
    await s.dispose();
    final old = _image;
    _image = null;
    old?.dispose();
  }

  Future<void> _connect(_CarEntry car) async {
    final device = _device;
    if (device == null) {
      setState(() => _error = 'No free Wi-Fi adapter. Plug in a second Wi-Fi dongle.');
      return;
    }
    String? password;
    if (car.scanned?.secured ?? false) {
      password = await _askPassword(car.name);
      if (password == null) return;
    }
    setState(() {
      _joining = car.ssid;
      _error = null;
    });
    try {
      await _closeSession();
      final adapter = await _net.join(device, car.ssid, password: password);
      final saved = await _store.remember(car.ssid, device);
      await _openSession(label: saved.name, device: adapter.device, ssid: car.ssid);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _joining = null);
      await _refreshAdapters();
    }
  }

  Future<void> _disconnect() async {
    final device = _session?.device;
    await _closeSession();
    if (device != null) await _net.leave(device);
    await _refreshAdapters();
  }

  void _onFrame(Uint8List jpeg) {
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
        if (!mounted || _session == null) {
          frame.image.dispose();
          break;
        }
        final old = _image;
        setState(() => _image = frame.image);
        old?.dispose();
      } catch (_) {
        // A damaged frame: keep the last good one.
      }
    }
    _decoding = false;
  }

  Future<void> _takePhoto() async {
    final s = _session;
    if (s == null) return;
    setState(() => _flash = true);
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _flash = false);
    });
    try {
      final f = await s.takePhoto();
      if (f != null) _toast('Photo saved: ${f.path}');
    } catch (e) {
      _toast("Couldn't save the photo: $e");
    }
  }

  Future<void> _toggleRecording() async {
    final s = _session;
    if (s == null || _changingRecording) return;
    _changingRecording = true;
    try {
      if (s.isRecording) {
        final r = await s.stopRecording();
        if (r != null) _toast('Video saved: ${r.$1.path} (${r.$2} frames)');
      } else {
        await s.startRecording();
      }
    } catch (e) {
      _toast("Couldn't save the video: $e");
    } finally {
      _changingRecording = false;
      if (mounted) setState(() {});
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
  }

  Future<String?> _askPassword(String name) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Password for $name'),
        content: TextField(
          controller: c,
          obscureText: true,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Join')),
        ],
      ),
    );
  }

  Future<void> _rename(_CarEntry car) async {
    final c = TextEditingController(text: car.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this car'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(helperText: car.ssid),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    if (_store.find(car.ssid) == null) await _store.remember(car.ssid, _device ?? '');
    await _store.rename(car.ssid, name);
    if (_sessionSsid == car.ssid) _session?.label = _store.find(car.ssid)!.name;
    setState(() {});
  }

  Future<void> _forget(_CarEntry car) async {
    await _store.forget(car.ssid);
    setState(() {});
  }

  void _openFolder(Directory dir) async {
    await dir.create(recursive: true);
    final opener = Platform.isWindows
        ? 'explorer'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    try {
      await Process.start(opener, [dir.path], mode: ProcessStartMode.detached);
    } catch (_) {
      _toast(dir.path);
    }
  }

  List<_CarEntry> get _entries {
    final map = <String, _CarEntry>{};
    for (final s in _store.cars) {
      map[s.ssid] = _CarEntry(s.ssid, saved: s);
    }
    for (final s in _scanned) {
      (map[s.ssid] ??= _CarEntry(s.ssid)).scanned = s;
    }
    final list = map.values.toList();
    list.sort((a, b) {
      if ((a.scanned != null) != (b.scanned != null)) return a.scanned != null ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape && _fullScreen) {
      _setFullScreen(false);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.f11) {
      _setFullScreen(!_fullScreen);
      return true;
    }
    return false;
  }

  Future<void> _setFullScreen(bool on) async {
    if (on == _fullScreen || !mounted) return;
    setState(() => _fullScreen = on);
    await _window.setFullScreen(on);
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final live = s?.isLive ?? false;
    final status = s == null
        ? (_managed ? 'Pick a car on the left' : 'Join the car Wi-Fi first')
        : (s.client.carBusy
              ? 'Another phone is using the car'
              : _image == null
              ? 'Starting video…'
              : 'Reconnecting…');
    return Scaffold(
      body: Row(
        children: [
          if (_managed && !_fullScreen) SizedBox(width: 330, child: _sidebar(context)),
          if (_managed && !_fullScreen) const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: CameraView(
                    image: _image,
                    isLive: live,
                    statusText: status,
                    isRecording: s?.isRecording ?? false,
                    recordingElapsed: s?.recordingElapsed ?? Duration.zero,
                    isFlashing: _flash,
                    onTakePhoto: _takePhoto,
                    onToggleRecording: _toggleRecording,
                    onHelp: _showHelp,
                    isFullScreen: _fullScreen,
                    onToggleFullScreen: () => _setFullScreen(!_fullScreen),
                  ),
                ),
                if (!_fullScreen) _bottomBar(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(BuildContext context) {
    final theme = Theme.of(context);
    final freeAdapters = _adapters.where((a) => a.isFree).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Cars', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            key: ValueKey(_adapters.map((a) => a.device).join(',')),
            initialValue: _device,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Wi-Fi adapter for the car'),
            items: [
              for (final a in _adapters)
                DropdownMenuItem(
                  value: a.device,
                  enabled: a.isFree,
                  child: Text(
                    '${a.device} · ${a.describe}${a.isFree ? '' : ' (in use)'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() {
              _device = v;
              _scanned = const [];
              _scan();
            }),
          ),
        ),
        if (_adapters.isNotEmpty && freeAdapters.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Every Wi-Fi adapter is in use for other networks. Plug in a USB '
              'Wi-Fi dongle for the car, so your internet stays on.',
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.tonalIcon(
            onPressed: _device == null || _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find),
            label: Text(_scanning ? 'Scanning…' : 'Scan for cars'),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final car in _entries) _carTile(car),
              if (_entries.isEmpty && !_scanning)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No cars yet. Turn a car on, wait a few seconds, then scan.'),
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ],
    );
  }

  Widget _carTile(_CarEntry car) {
    final connected = _sessionSsid == car.ssid;
    final joining = _joining == car.ssid;
    final subtitle = [
      if (car.saved != null && car.saved!.name != car.ssid) car.ssid,
      if (connected) 'Connected on ${_session?.device}',
      if (!connected && car.scanned != null) 'In range · ${car.scanned!.signal}%',
      if (!connected && car.scanned == null) 'Not seen in the last scan',
    ].join('\n');
    return ListTile(
      leading: Icon(
        Icons.directions_car,
        color: connected ? Colors.tealAccent : (car.scanned != null ? null : Colors.white38),
      ),
      title: Text(car.name),
      subtitle: Text(subtitle),
      isThreeLine: subtitle.contains('\n'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (joining)
            const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          else if (connected)
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.link_off),
              onPressed: _disconnect,
            )
          else
            IconButton(
              tooltip: 'Connect',
              icon: const Icon(Icons.login),
              onPressed: _joining == null && car.scanned != null ? () => _connect(car) : null,
            ),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'rename' ? _rename(car) : _forget(car),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              if (car.saved != null) const PopupMenuItem(value: 'forget', child: Text('Forget')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final url = _bridge.url;
    final folders = _session?.folders ?? MediaFolders.defaults();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const Icon(Icons.live_tv, size: 18),
            SelectableText(url == null ? 'VLC stream off' : 'VLC: $url'),
            if (url != null)
              IconButton(
                tooltip: 'Copy address',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  _toast('Copied. In VLC: Media › Open Network Stream, paste, Play.');
                },
              ),
            TextButton.icon(
              onPressed: () => _openFolder(folders.photos),
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Photos'),
            ),
            TextButton.icon(
              onPressed: () => _openFolder(folders.videos),
              icon: const Icon(Icons.video_library_outlined, size: 18),
              label: const Text('Videos'),
            ),
            if (_session != null) Text('${_session!.label} · ${_session!.framesReceived} frames'),
          ],
        ),
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How to connect'),
        content: const Text(
          '1. Switch the car on and wait for its light.\n'
          '2. Choose a Wi-Fi adapter that is not your internet one, '
          'usually a USB dongle.\n'
          '3. Scan, then press Connect next to the car (names start with 757-).\n\n'
          'Your internet stays on its own adapter: the car is never made the '
          'default route.\n\n'
          'Use the address at the bottom to watch the same video in VLC '
          '(Media › Open Network Stream).',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle.dispose();
    _closeSession();
    _bridge.stop();
    super.dispose();
  }
}
