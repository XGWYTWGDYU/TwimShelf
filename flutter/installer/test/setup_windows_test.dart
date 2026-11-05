@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tl_setup/setup.dart';

/// The real thing on a real Windows: the registry, the files and the shortcuts, under a synthetic
/// product of its own, in a temporary folder.
void main() {
  late Directory root;
  late String folder;
  late Setup v1, v2;

  Product product(String version) => Product(id: 'TwimShelf.SetupTest', name: 'TL Setup Test', version: version, publisher: 'test', executable: 'tl_setup_test_synthetic.exe');

  Future<String> payload(String name, Map<String, String> files) async {
    for (final e in files.entries) {
      await File('${root.path}\\$name\\${e.key}').create(recursive: true).then((f) => f.writeAsString(e.value));
    }
    return '${root.path}\\$name';
  }

  Future<void> install(Setup s, String from, {bool desktop = false}) => s.install(payload: from, setupFolder: '${root.path}\\setup', folder: folder, desktopShortcut: desktop, progress: (_) {});

  /// Uninstalls as the real setup does, with a short process standing in for it.
  Future<void> uninstall(Setup s) async {
    final setup = await Process.start('ping', ['127.0.0.1', '-n', '2']);
    await s.uninstall(folder: folder, progress: (_) {}, waitFor: setup.pid);
    await setup.exitCode;
    for (var i = 0; i < 30 && Directory(folder).existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tl_setup_test');
    folder = '${root.path}\\Installed';
    v1 = Setup(product('0.1.0'));
    v2 = Setup(product('0.2.0'));
    await File('${root.path}\\setup\\tl_setup.exe').create(recursive: true);
  });

  tearDown(() async {
    if (v1.installedCopy() != null) await uninstall(v1);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a folder with spaces and Chinese in its name is removed too', () async {
    folder = '${root.path}\\安装 位置\\TwimShelf';
    await install(v1, await payload('one', {'tl_setup_test_synthetic.exe': 'one'}));
    await uninstall(v1);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('install, see it, upgrade over it, uninstall', () async {
    expect(v1.installedCopy(), isNull);

    await install(v1, await payload('one', {'tl_setup_test_synthetic.exe': 'one', 'old.dll': 'old', 'keep.dat': 'one'}), desktop: true);
    final first = v2.installedCopy()!;
    expect(first.folder, folder);
    expect(first.version, '0.1.0');
    expect(installKind(first, '0.2.0'), InstallKind.upgrade);
    expect(installKind(first, '0.1.0'), InstallKind.reinstall);
    expect(installKind(first, '0.0.9'), InstallKind.downgrade);
    expect(v2.hasDesktopShortcut(), isTrue);

    // a file the person put in the folder is not the program's: an upgrade leaves it
    await File('$folder\\mine.txt').writeAsString('mine');
    await install(v2, await payload('two', {'tl_setup_test_synthetic.exe': 'two', 'keep.dat': 'two', 'new.dll': 'new'}));
    expect(v2.installedCopy()!.version, '0.2.0');
    expect(File('$folder\\old.dll').existsSync(), isFalse);
    expect(File('$folder\\new.dll').existsSync(), isTrue);
    expect(File('$folder\\keep.dat').readAsStringSync(), 'two');
    expect(File('$folder\\mine.txt').readAsStringSync(), 'mine');
    expect(File('$folder\\uninstall\\tl_setup.exe').existsSync(), isTrue);
    // unticked on the upgrade: the desktop shortcut goes
    expect(v2.hasDesktopShortcut(), isFalse);

    await uninstall(v2);
    expect(v2.installedCopy(), isNull);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('a folder gone by hand means not installed', () async {
    await install(v1, await payload('one', {'tl_setup_test_synthetic.exe': 'one'}));
    expect(v1.installedCopy(), isNotNull);
    Directory(folder).deleteSync(recursive: true);
    expect(v1.installedCopy(), isNull);
    // its entry and shortcut still have to go
    Directory(folder).createSync();
    await uninstall(v1);
  });
}
