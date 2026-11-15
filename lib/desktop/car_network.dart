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

  bool get isConnected => state == 'connected' || state.startsWith('connecting');

  /// Joined to a car and has an address from it.
  bool get onCar =>
      ssid != null && isCarSsid(ssid!) && (address?.startsWith(carSubnetPrefix) ?? false);

  /// Free for a car: not carrying some other network. An adapter already on a
  /// car counts as free, since switching cars on it loses nothing else.
  bool get isFree =>
      state != 'unmanaged' &&
      state != 'unavailable' &&
      (!isConnected || (ssid != null && isCarSsid(ssid!)));

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
  const ScannedCar({required this.ssid, required this.signal, required this.secured});

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
typedef CommandRunner = Future<ProcessResult> Function(String exe, List<String> args);

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
  Future<WifiAdapter> join(String device, String ssid, {String? password});

  Future<void> leave(String device);

  static CarNetwork forPlatform() {
    if (Platform.isLinux) return NetworkManagerCarNetwork();
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
  Future<WifiAdapter> join(String device, String ssid, {String? password}) =>
      throw CarNetworkException('Join the car Wi-Fi in your system settings.');
  @override
  Future<void> leave(String device) async {}
}

/// Linux, through `nmcli`. Joining needs NetworkManager's
/// network-control permission, which desktop users have by default.
class NetworkManagerCarNetwork implements CarNetwork {
  NetworkManagerCarNetwork({CommandRunner? run}) : _run = run ?? _runProcess;

  final CommandRunner _run;

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
      throw CarNetworkException(err.isEmpty ? 'nmcli failed (${r.exitCode})' : err);
    }
    return '${r.stdout}';
  }

  @override
  Future<List<WifiAdapter>> adapters() async {
    final out = await _nmcli(['-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION', 'device', 'status']);
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
        final show = await _nmcli(['-t', '-f', 'GENERAL.CONNECTION,IP4.ADDRESS', 'device', 'show', device]);
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
      final out = await _nmcli(['-g', '802-11-wireless.ssid', 'connection', 'show', 'id', connection]);
      final ssid = out.trim();
      return ssid.isEmpty ? null : ssid;
    } on CarNetworkException {
      return null;
    }
  }

  @override
  Future<List<ScannedCar>> scan(String device) async {
    final out = await _nmcli([
      '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list',
      'ifname', device, '--rescan', 'yes',
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
    'connection.interface-name', device,
    'connection.autoconnect', 'no',
    '802-11-wireless.ssid', ssid,
    'ipv4.method', 'auto',
    'ipv4.never-default', 'yes',
    'ipv4.ignore-auto-dns', 'yes',
    'ipv4.ignore-auto-routes', 'yes',
    'ipv6.method', 'ignore',
  ];

  /// Finds the saved profile for [ssid], by its SSID rather than its name.
  Future<String?> _findProfile(String ssid) async {
    final out = await _nmcli(['-t', '-f', 'NAME,UUID,TYPE', 'connection', 'show']);
    for (final line in out.split('\n')) {
      final f = splitTerse(line);
      if (f.length < 3 || f[2] != '802-11-wireless') continue;
      final profileSsid = await _profileSsid(f[0]);
      if (profileSsid == ssid) return f[1];
    }
    return null;
  }

  @override
  Future<WifiAdapter> join(String device, String ssid, {String? password}) async {
    if (!isCarSsid(ssid)) {
      throw CarNetworkException('$ssid is not a car network.');
    }
    final before = (await adapters()).where((a) => a.device == device);
    if (before.isEmpty) throw CarNetworkException('Adapter $device is gone.');
    final adapter = before.first;
    if (!adapter.isFree) {
      throw CarNetworkException(
        '$device is in use for ${adapter.ssid ?? 'another network'}; pick a free adapter.',
      );
    }

    var uuid = await _findProfile(ssid);
    if (uuid == null) {
      final out = await _nmcli([
        'connection', 'add', 'type', 'wifi',
        'con-name', profileNameFor(ssid),
        ...safetySettings(device, ssid),
        if (password != null && password.isNotEmpty) ...[
          'wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password,
        ],
      ]);
      uuid = RegExp(r'\(([0-9a-f-]{36})\)').firstMatch(out)?.group(1) ??
          await _findProfile(ssid);
      if (uuid == null) throw CarNetworkException('Could not save a profile for $ssid.');
    } else {
      // Reapply the safety settings in case the profile was edited, and move
      // it to this adapter.
      await _nmcli([
        'connection', 'modify', 'uuid', uuid,
        ...safetySettings(device, ssid),
        if (password != null && password.isNotEmpty) ...[
          'wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password,
        ],
      ]);
    }

    // The same car can only be on one adapter.
    for (final a in await adapters()) {
      if (a.device != device && a.ssid == ssid) await leave(a.device);
    }

    await _nmcli(['--wait', '30', 'connection', 'up', 'uuid', uuid, 'ifname', device]);

    final after = (await adapters()).firstWhere(
      (a) => a.device == device,
      orElse: () => throw CarNetworkException('Adapter $device is gone.'),
    );
    if (after.carriesDefaultRoute) {
      // Should never happen with never-default, but don't leave it that way.
      await leave(device);
      throw CarNetworkException('The car tried to become the internet route; disconnected.');
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
