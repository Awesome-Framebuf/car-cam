import 'dart:convert';
import 'dart:io';

/// A car the user has connected to before.
class SavedCar {
  SavedCar({required this.ssid, String? name, this.lastAdapter, this.lastUsed})
    : name = name ?? defaultName(ssid);

  final String ssid;

  /// What the user calls it, such as "Sam's car".
  String name;
  String? lastAdapter;
  DateTime? lastUsed;

  static String defaultName(String ssid) => ssid;

  Map<String, Object?> toJson() => {
    'ssid': ssid,
    'name': name,
    if (lastAdapter != null) 'lastAdapter': lastAdapter,
    if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
  };

  static SavedCar fromJson(Map<String, Object?> j) => SavedCar(
    ssid: j['ssid'] as String,
    name: j['name'] as String?,
    lastAdapter: j['lastAdapter'] as String?,
    lastUsed: DateTime.tryParse(j['lastUsed'] as String? ?? ''),
  );
}

/// Remembers cars in a small JSON file. Passwords, if a car has one, stay in
/// the system's network profile, not here.
class CarStore {
  CarStore(this.file);

  final File file;
  final cars = <SavedCar>[];

  static File defaultFile() {
    final env = Platform.environment;
    final String base;
    if (Platform.isWindows) {
      base = '${env['APPDATA'] ?? '.'}\\CarCam';
    } else {
      base = '${env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config'}/car-cam';
    }
    return File('$base${Platform.pathSeparator}cars.json');
  }

  Future<void> load() async {
    cars.clear();
    try {
      final data = jsonDecode(await file.readAsString());
      for (final j in (data['cars'] as List)) {
        cars.add(SavedCar.fromJson((j as Map).cast<String, Object?>()));
      }
    } catch (_) {
      // No file yet, or unreadable: start with no cars.
    }
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'cars': [for (final c in cars) c.toJson()]}),
    );
    await tmp.rename(file.path);
  }

  SavedCar? find(String ssid) {
    for (final c in cars) {
      if (c.ssid == ssid) return c;
    }
    return null;
  }

  /// Records a successful connection.
  Future<SavedCar> remember(String ssid, String adapter) async {
    final car = find(ssid) ?? (SavedCar(ssid: ssid)..also(cars.add));
    car
      ..lastAdapter = adapter
      ..lastUsed = DateTime.now();
    await save();
    return car;
  }

  Future<void> rename(String ssid, String name) async {
    final car = find(ssid);
    if (car == null) return;
    car.name = name.trim().isEmpty ? SavedCar.defaultName(ssid) : name.trim();
    await save();
  }

  Future<void> forget(String ssid) async {
    cars.removeWhere((c) => c.ssid == ssid);
    await save();
  }
}

extension _Also<T> on T {
  void also(void Function(T) f) => f(this);
}
