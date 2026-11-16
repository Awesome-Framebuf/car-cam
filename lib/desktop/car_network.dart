import 'dart:convert';
import 'dart:io';

/// Car Wi-Fi networks are named like `757-M64 A1B2C3`.
const carSsidPrefix = '757-';

/// Every car hands out addresses in this network and sits at `.1`.
const carSubnetPrefix = '192.168.169.';

bool isCarSsid(String ssid) => ssid.startsWith(carSsidPrefix);

/// One Wi-Fi adapter and what it's doing now.
class WifiAdapter {
  const WifiAdapter({
    required this.device,
    required this.state,
    this.connection,
    this.ssid,
    this.address,
    this.carriesDefaultRoute = false,
  });

  /// Interface name, such as `wlx001122334455`.
  final String device;

  /// NetworkManager's state word: `connected`, `disconnected`, `unavailable`…
  final String state;

  /// Name of the active NetworkManager profile, if any.
  final String? connection;

  /// Network the adapter is joined to, if any.
  final String? ssid;

  /// IPv4 address, if any.
  final String? address;

  /// True if the computer's internet goes through this adapter.
  final bool carriesDefaultRoute;

  bool get isConnected =>
      state == 'connected' || state.startsWith('connecting');

  /// Joined to a car and has an address from it.
  bool get onCar =>
      ssid != null &&
      isCarSsid(ssid!) &&
      (address?.startsWith(carSubnetPrefix) ?? false);

  /// Free for a car: not carrying some other network. An adapter already on a
  /// car counts as free, since switching cars on it loses nothing else.
  bool get isFree =>
      isUsable && (!isConnected || (ssid != null && isCarSsid(ssid!)));

  /// Can join a car at all. One that is not free is on another network, so
  /// joining takes it over (see [CarNetwork.join]).
  bool get isUsable => state != 'unmanaged' && state != 'unavailable';

  String get describe {
    if (onCar) return 'on $ssid';
    if (ssid != null && isConnected) {
      return carriesDefaultRoute ? 'internet ($ssid)' : 'on $ssid';
    }
    return state;
  }
}

/// A car network seen in a scan.
class ScannedCar {
  const ScannedCar({
    required this.ssid,
    required this.signal,
    required this.secured,
  });

  final String ssid;

  /// 0 to 100.
  final int signal;

  /// True if the network needs a password.
  final bool secured;
}

class CarNetworkException implements Exception {
  CarNetworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs a command and returns its exit code and output. Replaced in tests.
typedef CommandRunner = Future<ProcessResult> Function(
  String exe,
  List<String> args,
);

Future<ProcessResult> _runProcess(String exe, List<String> args) =>
    Process.run(exe, args, environment: const {'LC_ALL': 'C'});

/// Finds, joins and leaves car Wi-Fi networks.
///
/// The connection is per adapter: each car joins on one adapter and its video
/// client binds to that adapter, so several adapters can each hold a car.
abstract class CarNetwork {
  Future<List<WifiAdapter>> adapters();
  Future<List<ScannedCar>> scan(String device);

  /// Joins [ssid] on [device] without ever making it the default route.
  /// Returns the adapter's state once it has a car address.
  ///
  /// [device] must be free, unless [takeOver] is set: then it may be on
  /// another network (a PC's only Wi-Fi adapter), which it leaves for the
  /// car, and [leave] puts it back on that network.
  Future<WifiAdapter> join(
    String device,
    String ssid, {
    String? password,
    bool takeOver = false,
  });

  /// Leaves the car on [device]. If [join] took the adapter over, it goes
  /// back to the network it was on.
  Future<void> leave(String device);

  static CarNetwork forPlatform() {
    if (Platform.isLinux) return NetworkManagerCarNetwork();
    if (Platform.isWindows) return WindowsCarNetwork();
    return UnsupportedCarNetwork();
  }
}

/// For platforms without automatic joining yet: the user joins by hand.
class UnsupportedCarNetwork implements CarNetwork {
  @override
  Future<List<WifiAdapter>> adapters() async => const [];
  @override
  Future<List<ScannedCar>> scan(String device) async => const [];
  @override
  Future<WifiAdapter> join(
    String device,
    String ssid, {
    String? password,
    bool takeOver = false,
  }) =>
      throw CarNetworkException('Join the car Wi-Fi in your system settings.');
  @override
  Future<void> leave(String device) async {}
}

/// Linux, through `nmcli`. Joining needs NetworkManager's
/// network-control permission, which desktop users have by default.
class NetworkManagerCarNetwork implements CarNetwork {
  NetworkManagerCarNetwork({CommandRunner? run}) : _run = run ?? _runProcess;

  final CommandRunner _run;

  /// Network each taken-over adapter was on before the car, by adapter.
  final _previous = <String, String>{};

  /// Profiles this app makes are named `car-<last word of the SSID>`.
  static const profilePrefix = 'car-';

  Future<String> _nmcli(List<String> args) async {
    final ProcessResult r;
    try {
      r = await _run('nmcli', args);
    } on ProcessException {
      throw CarNetworkException('NetworkManager (nmcli) was not found.');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      throw CarNetworkException(
        err.isEmpty ? 'nmcli failed (${r.exitCode})' : err,
      );
    }
    return '${r.stdout}';
  }

  @override
  Future<List<WifiAdapter>> adapters() async {
    final out = await _nmcli([
      '-t',
      '-f',
      'DEVICE,TYPE,STATE,CONNECTION',
      'device',
      'status',
    ]);
    final defaults = await _defaultRouteDevices();
    final result = <WifiAdapter>[];
    for (final line in out.split('\n')) {
      final f = splitTerse(line);
      if (f.length < 4 || f[1] != 'wifi') continue;
      final device = f[0];
      final connection = f[3].isEmpty || f[3] == '--' ? null : f[3];
      String? ssid;
      String? address;
      if (connection != null) {
        final show = await _nmcli([
          '-t',
          '-f',
          'GENERAL.CONNECTION,IP4.ADDRESS',
          'device',
          'show',
          device,
        ]);
        for (final l in show.split('\n')) {
          final kv = splitTerse(l);
          if (kv.length >= 2 && kv[0].startsWith('IP4.ADDRESS')) {
            address ??= kv[1].split('/').first;
          }
        }
        ssid = await _profileSsid(connection);
      }
      result.add(
        WifiAdapter(
          device: device,
          state: f[2],
          connection: connection,
          ssid: ssid,
          address: address,
          carriesDefaultRoute: defaults.contains(device),
        ),
      );
    }
    return result;
  }

  Future<Set<String>> _defaultRouteDevices() async {
    try {
      final r = await _run('ip', ['-4', 'route', 'show', 'default']);
      final devices = <String>{};
      for (final m in RegExp(r'\bdev (\S+)').allMatches('${r.stdout}')) {
        devices.add(m.group(1)!);
      }
      return devices;
    } on ProcessException {
      return const {};
    }
  }

  Future<String?> _profileSsid(String connection) async {
    try {
      final out = await _nmcli([
        '-g',
        '802-11-wireless.ssid',
        'connection',
        'show',
        'id',
        connection,
      ]);
      final ssid = out.trim();
      return ssid.isEmpty ? null : ssid;
    } on CarNetworkException {
      return null;
    }
  }

  @override
  Future<List<ScannedCar>> scan(String device) async {
    final out = await _nmcli([
      '-t',
      '-f',
      'SSID,SIGNAL,SECURITY',
      'device',
      'wifi',
      'list',
      'ifname',
      device,
      '--rescan',
      'yes',
    ]);
    return parseScan(out);
  }

  static List<ScannedCar> parseScan(String out) {
    final best = <String, ScannedCar>{};
    for (final line in out.split('\n')) {
      final f = splitTerse(line);
      if (f.length < 3 || !isCarSsid(f[0])) continue;
      final car = ScannedCar(
        ssid: f[0],
        signal: int.tryParse(f[1]) ?? 0,
        secured: f[2].trim().isNotEmpty && f[2].trim() != '--',
      );
      final seen = best[car.ssid];
      if (seen == null || seen.signal < car.signal) best[car.ssid] = car;
    }
    return best.values.toList()..sort((a, b) => b.signal.compareTo(a.signal));
  }

  static String profileNameFor(String ssid) {
    final word = ssid.trim().split(RegExp(r'\s+')).last;
    final safe = word.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return '$profilePrefix${safe.isEmpty ? 'car' : safe}';
  }

  /// The settings that keep a car from taking over the internet: never the
  /// default route, no DNS from the car, no IPv6, no joining by itself.
  static List<String> safetySettings(String device, String ssid) => [
    'connection.interface-name',
    device,
    'connection.autoconnect',
    'no',
    '802-11-wireless.ssid',
    ssid,
    'ipv4.method',
    'auto',
    'ipv4.never-default',
    'yes',
    'ipv4.ignore-auto-dns',
    'yes',
    'ipv4.ignore-auto-routes',
    'yes',
    'ipv6.method',
    'ignore',
  ];

  /// Finds the saved profile for [ssid], by its SSID rather than its name.
  Future<String?> _findProfile(String ssid) async {
    final out = await _nmcli([
      '-t',
      '-f',
      'NAME,UUID,TYPE',
      'connection',
      'show',
    ]);
    for (final line in out.split('\n')) {
      final f = splitTerse(line);
      if (f.length < 3 || f[2] != '802-11-wireless') continue;
      final profileSsid = await _profileSsid(f[0]);
      if (profileSsid == ssid) return f[1];
    }
    return null;
  }

  @override
  Future<WifiAdapter> join(
    String device,
    String ssid, {
    String? password,
    bool takeOver = false,
  }) async {
    if (!isCarSsid(ssid)) {
      throw CarNetworkException('$ssid is not a car network.');
    }
    final before = (await adapters()).where((a) => a.device == device);
    if (before.isEmpty) throw CarNetworkException('Adapter $device is gone.');
    final adapter = before.first;
    if (!adapter.isUsable || (!adapter.isFree && !takeOver)) {
      throw CarNetworkException(
        '$device is in use for ${adapter.ssid ?? 'another network'}; pick a free adapter.',
      );
    }
    if (!adapter.isFree && adapter.connection != null) {
      _previous[device] = adapter.connection!;
    }

    var uuid = await _findProfile(ssid);
    if (uuid == null) {
      final out = await _nmcli([
        'connection',
        'add',
        'type',
        'wifi',
        'con-name',
        profileNameFor(ssid),
        ...safetySettings(device, ssid),
        if (password != null && password.isNotEmpty) ...[
          'wifi-sec.key-mgmt',
          'wpa-psk',
          'wifi-sec.psk',
          password,
        ],
      ]);
      uuid =
          RegExp(r'\(([0-9a-f-]{36})\)').firstMatch(out)?.group(1) ??
          await _findProfile(ssid);
      if (uuid == null)
        throw CarNetworkException('Could not save a profile for $ssid.');
    } else {
      // Reapply the safety settings in case the profile was edited, and move
      // it to this adapter.
      await _nmcli([
        'connection',
        'modify',
        'uuid',
        uuid,
        ...safetySettings(device, ssid),
        if (password != null && password.isNotEmpty) ...[
          'wifi-sec.key-mgmt',
          'wpa-psk',
          'wifi-sec.psk',
          password,
        ],
      ]);
    }

    // The same car can only be on one adapter.
    for (final a in await adapters()) {
      if (a.device != device && a.ssid == ssid) await leave(a.device);
    }

    await _nmcli([
      '--wait',
      '30',
      'connection',
      'up',
      'uuid',
      uuid,
      'ifname',
      device,
    ]);

    final after = (await adapters()).firstWhere(
      (a) => a.device == device,
      orElse: () => throw CarNetworkException('Adapter $device is gone.'),
    );
    if (after.carriesDefaultRoute) {
      // Should never happen with never-default, but don't leave it that way.
      await leave(device);
      throw CarNetworkException(
        'The car tried to become the internet route; disconnected.',
      );
    }
    if (!after.onCar) {
      throw CarNetworkException('Joined $ssid but got no car address yet.');
    }
    return after;
  }

  @override
  Future<void> leave(String device) async {
    try {
      await _nmcli(['device', 'disconnect', device]);
    } on CarNetworkException {
      // Already disconnected.
    }
    final previous = _previous.remove(device);
    if (previous != null) {
      try {
        await _nmcli([
          '--wait',
          '30',
          'connection',
          'up',
          'id',
          previous,
          'ifname',
          device,
        ]);
      } on CarNetworkException {
        // Out of range now: NetworkManager reconnects by itself later.
      }
    }
  }
}

/// IPv4 address per interface name. Replaced in tests.
typedef AddressLookup = Future<Map<String, String>> Function();

Future<Map<String, String>> _interfaceAddresses() async {
  final result = <String, String>{};
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    if (i.addresses.isNotEmpty) result[i.name] = i.addresses.first.address;
  }
  return result;
}

Future<ProcessResult> _runWindows(String exe, List<String> args) =>
    Process.run(exe, args, runInShell: false);

/// Windows, through `netsh wlan` and PowerShell.
///
/// Arguments with spaces are passed as `name=Wi-Fi 2`, which Dart quotes as a
/// whole (`"name=Wi-Fi 2"`); netsh accepts that form.
///
/// The car's DHCP offers itself as gateway and DNS, which Windows takes. The
/// [join] checks the default route afterwards: if the car took it from
/// another adapter's internet, it raises the car adapter's metric once (one
/// elevated prompt) or backs out.
class WindowsCarNetwork implements CarNetwork {
  WindowsCarNetwork({
    CommandRunner? run,
    AddressLookup? addresses,
    this.pollInterval = const Duration(milliseconds: 500),
    this.addressTimeout = const Duration(seconds: 20),
    this.rescanDelay = const Duration(seconds: 3),
  }) : _run = run ?? _runWindows,
       _addresses = addresses ?? _interfaceAddresses;

  final CommandRunner _run;
  final AddressLookup _addresses;

  /// Wi-Fi profile each taken-over adapter was on before the car, by adapter.
  final _previous = <String, String>{};
  final Duration pollInterval;
  final Duration addressTimeout;
  final Duration rescanDelay;

  /// Metric given to the car's adapter so it never wins the default route.
  static const carMetric = 9000;

  Future<String> _exec(String exe, List<String> args) async {
    final ProcessResult r;
    try {
      r = await _run(exe, args);
    } on ProcessException {
      throw CarNetworkException('$exe was not found.');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      final out = '${r.stdout}'.trim();
      throw CarNetworkException(
        err.isNotEmpty
            ? err
            : (out.isNotEmpty ? out : '$exe failed (${r.exitCode})'),
      );
    }
    return '${r.stdout}';
  }

  Future<String> _netsh(List<String> args) => _exec('netsh', ['wlan', ...args]);

  Future<String> _powershell(String command) => _exec('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);

  /// Splits `netsh` output into `key : value` blocks, a new block at each
  /// [firstKey]. Keys are trimmed; values keep their inner spaces.
  static List<Map<String, String>> parseBlocks(String out, String firstKey) {
    final blocks = <Map<String, String>>[];
    for (final raw in const LineSplitter().convert(out)) {
      final i = raw.indexOf(':');
      if (i < 0) continue;
      final key = raw.substring(0, i).trim();
      final value = raw.substring(i + 1).trim();
      if (key == firstKey) blocks.add({});
      if (blocks.isNotEmpty) blocks.last.putIfAbsent(key, () => value);
    }
    return blocks;
  }

  /// `netsh wlan show interfaces`: one block per adapter, English output.
  static List<({String name, String state, String? ssid})> parseInterfaces(
    String out,
  ) => [
    for (final b in parseBlocks(out, 'Name'))
      (
        name: b['Name']!,
        state: (b['State'] ?? 'disconnected').toLowerCase(),
        ssid: (b['SSID'] ?? '').isEmpty ? null : b['SSID'],
      ),
  ];

  /// The adapter that carries the default route now: lowest route metric plus
  /// interface metric, the way Windows picks it.
  Future<String?> defaultRouteAdapter() async {
    try {
      final out = await _powershell(
        r'Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | '
        r'Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } | '
        r'Select-Object -First 1 -ExpandProperty InterfaceAlias',
      );
      final alias = out.trim();
      return alias.isEmpty ? null : alias;
    } on CarNetworkException {
      return null;
    }
  }

  @override
  Future<List<WifiAdapter>> adapters() async {
    final out = await _netsh(['show', 'interfaces']);
    var found = parseInterfaces(out);
    if (found.isEmpty &&
        out.trim().isNotEmpty &&
        !out.contains('There is no')) {
      // Not English: fall back to PowerShell for names and states.
      found = await _adaptersFromPowerShell();
    }
    final addresses = await _addresses();
    final route = await defaultRouteAdapter();
    return [
      for (final a in found)
        WifiAdapter(
          device: a.name,
          state: a.state,
          connection: a.ssid == null
              ? null
              : NetworkManagerCarNetwork.profileNameFor(a.ssid!),
          ssid: a.ssid,
          address: addresses[a.name],
          carriesDefaultRoute: route != null && route == a.name,
        ),
    ];
  }

  Future<List<({String name, String state, String? ssid})>>
  _adaptersFromPowerShell() async {
    final out = await _powershell(
      r"Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match '802\.11' } | "
      r"ForEach-Object { $p = Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue; "
      r"'{0}|{1}|{2}' -f $_.Name, $_.Status, $p.Name }",
    );
    return [
      for (final line in const LineSplitter().convert(out))
        if (line.split('|').length >= 3)
          () {
            final f = line.split('|');
            final up = f[1].trim().toLowerCase() == 'up';
            return (
              name: f[0].trim(),
              state: up ? 'connected' : 'disconnected',
              ssid: up && f[2].trim().isNotEmpty ? f[2].trim() : null,
            );
          }(),
    ];
  }

  @override
  Future<List<ScannedCar>> scan(String device) async {
    final args = ['show', 'networks', 'interface=$device', 'mode=bssid'];
    var cars = parseScan(await _netsh(args));
    if (cars.isEmpty) {
      // Windows serves cached scans; give it a moment to refresh once.
      await Future<void>.delayed(rescanDelay);
      cars = parseScan(await _netsh(args));
    }
    return cars;
  }

  /// `netsh wlan show networks mode=bssid`: cars only, strongest first, one
  /// per name.
  static List<ScannedCar> parseScan(String out) {
    final best = <String, ScannedCar>{};
    String? ssid;
    var secured = false;
    var signal = 0;
    void flush() {
      final s = ssid;
      if (s == null || !isCarSsid(s)) return;
      final car = ScannedCar(ssid: s, signal: signal, secured: secured);
      final seen = best[s];
      if (seen == null || seen.signal < car.signal) best[s] = car;
    }

    for (final raw in const LineSplitter().convert(out)) {
      final i = raw.indexOf(':');
      if (i < 0) continue;
      final key = raw.substring(0, i).trim();
      final value = raw.substring(i + 1).trim();
      if (RegExp(r'^SSID \d+$').hasMatch(key)) {
        flush();
        ssid = value;
        secured = false;
        signal = 0;
      } else if (key == 'Authentication') {
        secured = value.toLowerCase() != 'open';
      } else if (key == 'Signal') {
        final v = int.tryParse(value.replaceAll('%', '').trim()) ?? 0;
        if (v > signal) signal = v;
      }
    }
    flush();
    return best.values.toList()..sort((a, b) => b.signal.compareTo(a.signal));
  }

  static String xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// A WLAN profile that joins only when asked (`manual`).
  static String profileXml(String ssid, {String? password}) {
    final name = NetworkManagerCarNetwork.profileNameFor(ssid);
    final hex = utf8
        .encode(ssid)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final secured = password != null && password.isNotEmpty;
    final auth = secured
        ? '<authentication>WPA2PSK</authentication><encryption>AES</encryption>'
              '<useOneX>false</useOneX></authEncryption>'
              '<sharedKey><keyType>passPhrase</keyType><protected>false</protected>'
              '<keyMaterial>${xmlEscape(password)}</keyMaterial></sharedKey>'
        : '<authentication>open</authentication><encryption>none</encryption>'
              '<useOneX>false</useOneX></authEncryption>';
    return '<?xml version="1.0"?>\n'
        '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">'
        '<name>${xmlEscape(name)}</name>'
        '<SSIDConfig><SSID><hex>$hex</hex><name>${xmlEscape(ssid)}</name></SSID></SSIDConfig>'
        '<connectionType>ESS</connectionType>'
        '<connectionMode>manual</connectionMode>'
        '<MSM><security><authEncryption>$auth</security></MSM>'
        '</WLANProfile>\n';
  }

  /// PowerShell that raises the adapter's metric, run elevated once.
  static String metricFixCommand(String device) {
    final alias = device.replaceAll("'", "''");
    final inner =
        "Set-NetIPInterface -InterfaceAlias '$alias' -AddressFamily IPv4 -InterfaceMetric $carMetric; "
        "Set-DnsClient -InterfaceAlias '$alias' -RegisterThisConnectionsAddress \$false";
    // UTF-16LE base64, so no quoting survives the trip through Start-Process.
    final bytes = <int>[];
    for (final c in inner.codeUnits) {
      bytes
        ..add(c & 0xFF)
        ..add(c >> 8);
    }
    return "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden "
        "-ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','${base64.encode(bytes)}'";
  }

  @override
  Future<WifiAdapter> join(
    String device,
    String ssid, {
    String? password,
    bool takeOver = false,
  }) async {
    if (!isCarSsid(ssid)) {
      throw CarNetworkException('$ssid is not a car network.');
    }
    final before = (await adapters()).where((a) => a.device == device);
    if (before.isEmpty) throw CarNetworkException('Adapter $device is gone.');
    final adapter = before.first;
    if (!adapter.isUsable || (!adapter.isFree && !takeOver)) {
      throw CarNetworkException(
        '$device is in use for ${adapter.ssid ?? 'another network'}; pick a free adapter.',
      );
    }
    if (!adapter.isFree) {
      final block = parseBlocks(
        await _netsh(['show', 'interfaces']),
        'Name',
      ).where((b) => b['Name'] == device);
      final profile = block.isEmpty
          ? null
          : (block.first['Profile'] ?? block.first['SSID']);
      if (profile != null && profile.isNotEmpty) _previous[device] = profile;
    }

    final profile = NetworkManagerCarNetwork.profileNameFor(ssid);
    final dir = await Directory.systemTemp.createTemp('carcam');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}$profile.xml');
      await file.writeAsString(profileXml(ssid, password: password));
      await _netsh([
        'add',
        'profile',
        'filename=${file.path}',
        'interface=$device',
        'user=current',
      ]);
    } finally {
      await dir.delete(recursive: true);
    }

    // The same car can only be on one adapter.
    for (final a in await adapters()) {
      if (a.device != device && a.ssid == ssid) await leave(a.device);
    }

    await _netsh([
      'connect',
      'name=$profile',
      'ssid=$ssid',
      'interface=$device',
    ]);

    final deadline = DateTime.now().add(addressTimeout);
    while (!((await _addresses())[device]?.startsWith(carSubnetPrefix) ??
        false)) {
      if (DateTime.now().isAfter(deadline)) {
        await leave(device);
        throw CarNetworkException('Joined $ssid but got no car address.');
      }
      await Future<void>.delayed(pollInterval);
    }

    if (await defaultRouteAdapter() == device &&
        await _hasOtherDefaultRoute(device)) {
      // The car's DHCP made it the gateway over the real internet. Push it
      // down once, elevated. (With no other route there is no internet to
      // protect, as when the PC's only Wi-Fi adapter is on the car.)
      try {
        await _powershell(metricFixCommand(device));
      } on CarNetworkException {
        // Cancelled or failed: checked below.
      }
      if (await defaultRouteAdapter() == device) {
        await leave(device);
        throw CarNetworkException(
          'The car tried to become the internet route; disconnected.',
        );
      }
    }

    final after = (await adapters()).firstWhere(
      (a) => a.device == device,
      orElse: () => throw CarNetworkException('Adapter $device is gone.'),
    );
    if (!after.onCar) {
      throw CarNetworkException('Joined $ssid but got no car address yet.');
    }
    return after;
  }

  /// True if an adapter other than [device] has a default route.
  Future<bool> _hasOtherDefaultRoute(String device) async {
    try {
      final out = await _powershell(
        r'Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | '
        r'Select-Object -ExpandProperty InterfaceAlias',
      );
      return const LineSplitter()
          .convert(out)
          .any((l) => l.trim().isNotEmpty && l.trim() != device);
    } on CarNetworkException {
      return true;
    }
  }

  @override
  Future<void> leave(String device) async {
    try {
      await _netsh(['disconnect', 'interface=$device']);
    } on CarNetworkException {
      // Already disconnected.
    }
    final previous = _previous.remove(device);
    if (previous != null) {
      try {
        await _netsh(['connect', 'name=$previous', 'interface=$device']);
      } on CarNetworkException {
        // Out of range now: Windows reconnects by itself later.
      }
    }
  }
}

/// Splits one line of `nmcli -t` output, which escapes `:` and `\` with `\`.
List<String> splitTerse(String line) {
  final fields = <String>[];
  final cur = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == r'\' && i + 1 < line.length) {
      cur.write(line[++i]);
    } else if (c == ':') {
      fields.add(cur.toString());
      cur.clear();
    } else {
      cur.write(c);
    }
  }
  fields.add(cur.toString());
  return fields;
}
