import 'dart:convert';
import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// What the setup knows about the app it installs (`payload.json`, written by the build).
class Product {
  Product({required this.id, required this.name, required this.version, required this.publisher, required this.executable});
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        name: j['name'] as String,
        version: j['version'] as String,
        publisher: j['publisher'] as String? ?? '',
        executable: j['executable'] as String,
      );
  /// The uninstall entry's key name (letters, digits, dots).
  final String id;
  final String name, version, publisher;
  /// The program inside the install folder (e.g. `TwimShelf.exe`).
  final String executable;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'version': version, 'publisher': publisher, 'executable': executable};
}

/// A copy already on this computer. [version] is null when no record of it can be read.
class InstalledCopy {
  const InstalledCopy({required this.folder, this.version});
  final String folder;
  final String? version;
}

/// What running this setup would do to what is there.
enum InstallKind { fresh, upgrade, reinstall, downgrade, unknownVersion }

InstallKind installKind(InstalledCopy? copy, String incoming) {
  if (copy == null) return InstallKind.fresh;
  final installed = copy.version;
  final order = installed == null ? null : compareVersions(installed, incoming);
  return switch (order) {
    null => InstallKind.unknownVersion,
    0 => InstallKind.reinstall,
    < 0 => InstallKind.upgrade,
    _ => InstallKind.downgrade,
  };
}

/// Compares dotted versions (`1.2`, `1.2.0+3`; a build number counts as one more part, missing
/// parts as 0). Null when either has a part that is not a number.
int? compareVersions(String a, String b) {
  List<int>? parts(String v) {
    final out = <int>[];
    for (final p in v.trim().split(RegExp(r'[.+]'))) {
      final n = int.tryParse(p);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }

  final x = parts(a), y = parts(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Installing for this user only: no administrator rights, nothing outside the user's own
/// folders and registry. Everything the program needs is in one folder:
///   `folder`\…               the program
///   `folder`\uninstall\      this setup (Apps & Features runs it to remove the program)
///   `folder`\install-manifest.json   the program's files (an update removes those it no longer has)
/// Plus a Start menu shortcut (and a desktop one if asked) and the Apps & Features entry.
class Setup {
  Setup(this.product);
  final Product product;

  static String get _local => Platform.environment['LOCALAPPDATA']!;
  static String get _appData => Platform.environment['APPDATA']!;
  String get defaultFolder => '$_local\\Programs\\${product.name}';
  String get _uninstallKey => 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${product.id}';
  String get _startMenu => '$_appData\\Microsoft\\Windows\\Start Menu\\Programs\\${product.name}.lnk';
  String get _desktop => '${Platform.environment['USERPROFILE']}\\Desktop\\${product.name}.lnk';

  /// The copy installed now (null: not installed).
  InstalledCopy? installedCopy() {
    try {
      final k = CURRENT_USER.open(_uninstallKey);
      final p = k.getString('InstallLocation');
      final v = k.getString('DisplayVersion');
      k.close();
      return p != null && Directory(p).existsSync() ? InstalledCopy(folder: p, version: v ?? _manifestVersion(p)) : null;
    } catch (_) {
      return null;
    }
  }

  String? _manifestVersion(String folder) {
    try {
      return (jsonDecode(File('$folder\\install-manifest.json').readAsStringSync()) as Map)['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  bool hasDesktopShortcut() => File(_desktop).existsSync();

  /// Asks a running copy of the program to quit (it would keep its files locked).
  Future<void> closeRunning() async {
    await Process.run('taskkill', ['/IM', product.executable, '/T']);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  /// Copies [payload] into [folder] (replacing an older version there), then the shortcuts and
  /// the uninstall entry. [progress] gets the share done (0–1).
  Future<void> install({required String payload, required String setupFolder, required String folder, required bool desktopShortcut,
      required void Function(double) progress}) async {
    await closeRunning();
    final files = Directory(payload).listSync(recursive: true, followLinks: false).whereType<File>().toList();
    final total = files.fold<int>(0, (a, f) => a + f.lengthSync());
    final manifest = <String>[];
    var done = 0;
    final target = Directory(folder);
    // an older version's files that the new one does not have go (only in its own folder)
    final previous = File('$folder\\install-manifest.json');
    final old = previous.existsSync() ? ((jsonDecode(previous.readAsStringSync()) as Map)['files'] as List).cast<String>().toSet() : <String>{};
    await target.create(recursive: true);
    for (final f in files) {
      final rel = f.path.substring(payload.length + 1);
      final dst = File('$folder\\$rel');
      await dst.parent.create(recursive: true);
      await f.copy(dst.path);
      manifest.add(rel);
      old.remove(rel);
      done += f.lengthSync();
      progress(total == 0 ? 1 : done / total * 0.9);
    }
    for (final rel in old) {
      final f = File('$folder\\$rel');
      if (f.existsSync()) f.deleteSync();
    }
    // this setup, for removing the program later
    final uninstall = Directory('$folder\\uninstall');
    if (uninstall.existsSync()) uninstall.deleteSync(recursive: true);
    await _copyTree(setupFolder, uninstall.path);
    await File('${uninstall.path}\\payload.json').writeAsString(jsonEncode(product.toJson()));
    await File('$folder\\install-manifest.json').writeAsString(jsonEncode({'version': product.version, 'files': manifest}));
    progress(0.95);
    final exe = '$folder\\${product.executable}';
    await _shortcut(_startMenu, exe, folder);
    if (desktopShortcut) {
      await _shortcut(_desktop, exe, folder);
    } else if (File(_desktop).existsSync()) {
      File(_desktop).deleteSync();
    }
    final setupExe = '${uninstall.path}\\tl_setup.exe';
    final k = CURRENT_USER.create(_uninstallKey);
    k.setValue('DisplayName', RegistryValue.string(product.name));
    k.setValue('DisplayVersion', RegistryValue.string(product.version));
    k.setValue('Publisher', RegistryValue.string(product.publisher));
    k.setValue('DisplayIcon', RegistryValue.string(exe));
    k.setValue('InstallLocation', RegistryValue.string(folder));
    k.setValue('UninstallString', RegistryValue.string('"$setupExe" --uninstall'));
    k.setValue('EstimatedSize', RegistryValue.dword(total ~/ 1024));
    k.setValue('NoModify', const RegistryValue.dword(1));
    k.setValue('NoRepair', const RegistryValue.dword(1));
    k.close();
    progress(1);
  }

  /// Removes the program, its shortcuts and its entry; the data folder only when asked.
  /// The folder itself goes once the process [waitFor] (this setup, by default) has ended.
  Future<void> uninstall({required String folder, String? dataFolder, required void Function(double) progress, int? waitFor}) async {
    await closeRunning();
    for (final s in [_startMenu, _desktop]) {
      final f = File(s);
      if (f.existsSync()) f.deleteSync();
    }
    progress(0.2);
    try {
      CURRENT_USER.open('Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall', config: const RegistryOpenConfig(access: RegistryAccess.readWrite)).removeSubkey(product.id);
    } catch (_) {}
    progress(0.4);
    // the folder holds this running setup: everything else now, the rest after it quits
    for (final e in Directory(folder).listSync()) {
      if (e.path.toLowerCase() == '$folder\\uninstall'.toLowerCase()) continue;
      e.deleteSync(recursive: true);
    }
    progress(0.8);
    if (dataFolder != null && File('$dataFolder\\twimshelf-data.json').existsSync()) {
      await Directory(dataFolder).delete(recursive: true);
      final pointer = File('$_appData\\TwimShelf\\location.json');
      if (pointer.existsSync()) pointer.deleteSync();
    }
    progress(1);
    // a command waits for this process to end (the window stays open until the person closes it,
    // and its files are in use until then), then removes the folder. It outlives this process
    // anyway, and started in detached mode it does not run at all. Encoded, so that no quoting
    // stands between it and a folder with spaces or Chinese in its name.
    String q(String v) => v.replaceAll("'", "''");
    final script = "Wait-Process -Id ${waitFor ?? pid} -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '${q(folder)}' -Recurse -Force";
    final encoded = base64Encode(script.codeUnits.expand((u) => [u & 0xff, u >> 8]).toList());
    await Process.start('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], workingDirectory: Directory.systemTemp.path);
  }

  /// The data folder the app uses (from its pointer), if there is one that carries the app's
  /// mark: nothing else can be offered for deletion.
  String? dataFolder() {
    try {
      final j = jsonDecode(File('$_appData\\TwimShelf\\location.json').readAsStringSync()) as Map;
      final path = j['path'] as String?;
      return path != null && File('$path\\twimshelf-data.json').existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _copyTree(String from, String to) async {
    for (final f in Directory(from).listSync(recursive: true, followLinks: false).whereType<File>()) {
      final dst = File('$to\\${f.path.substring(from.length + 1)}');
      await dst.parent.create(recursive: true);
      await f.copy(dst.path);
    }
  }

  /// A .lnk through the shell's own scripting object (no extra component needed).
  static Future<void> _shortcut(String link, String target, String workingDir) async {
    String q(String s) => s.replaceAll("'", "''");
    await File(link).parent.create(recursive: true);
    final r = await Process.run('powershell', [
      '-NoProfile', '-NonInteractive', '-Command',
      "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('${q(link)}');\$s.TargetPath='${q(target)}';\$s.WorkingDirectory='${q(workingDir)}';\$s.IconLocation='${q(target)},0';\$s.Save()",
    ]);
    if (r.exitCode != 0) throw ProcessException('powershell', const [], '${r.stderr}', r.exitCode);
  }
}
