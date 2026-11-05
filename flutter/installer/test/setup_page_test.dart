import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_setup/setup.dart';
import 'package:tl_setup/setup_page.dart';
import 'package:tl_setup/strings.dart';

const _folder = r'C:\Users\synthetic\AppData\Local\Programs\TwimShelf';
const _data = r'C:\Users\synthetic\Documents\TwimShelf Data';

class FakeSetup extends Setup {
  FakeSetup(super.product, {this.copy, this.data, this.desktop = false, this.failures = 0});
  final InstalledCopy? copy;
  final String? data;
  final bool desktop;
  int failures;
  String? installedTo, removedData;
  bool? shortcut;
  int runs = 0;

  @override
  InstalledCopy? installedCopy() => copy;
  @override
  String get defaultFolder => _folder;
  @override
  bool hasDesktopShortcut() => desktop;
  @override
  String? dataFolder() => data;
  @override
  Future<void> install({required String payload, required String setupFolder, required String folder, required bool desktopShortcut, required void Function(double) progress}) async {
    runs++;
    if (failures-- > 0) throw const FormatException('synthetic: file in use');
    installedTo = folder;
    shortcut = desktopShortcut;
    progress(1);
  }

  @override
  Future<void> uninstall({required String folder, String? dataFolder, required void Function(double) progress, int? waitFor}) async {
    runs++;
    removedData = dataFolder;
    progress(1);
  }
}

Product _product([String version = '0.2.0']) => Product(id: 'synthetic.app', name: 'TwimShelf', version: version, publisher: '', executable: 'app.exe');
final _s = S.of(const Locale('en'));

Future<FakeSetup> _pump(WidgetTester t, {Mode mode = Mode.install, InstalledCopy? copy, String? data, bool desktop = false, int failures = 0}) async {
  await t.binding.setSurfaceSize(const Size(640, 520));
  final fake = FakeSetup(_product(), copy: copy, data: data, desktop: desktop, failures: failures);
  await t.pumpWidget(MaterialApp(
    home: SetupPage(product: fake.product, mode: mode, payload: 'payload', setupFolder: r'C:\setup', strings: _s, setup: fake),
  ));
  await t.pump();
  return fake;
}

Future<void> _go(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('go')));
  await t.pump();
  await t.pump();
}

InstalledCopy _copy(String? version) => InstalledCopy(folder: r'D:\Apps\TwimShelf', version: version);

void main() {
  group('versions', () {
    test('compare by number, not by text', () {
      expect(compareVersions('0.9.0', '0.10.0'), lessThan(0));
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2.0+3', '1.2.0+2'), greaterThan(0));
      expect(compareVersions('1.2-beta', '1.2'), isNull);
    });
    test('what is there decides what this setup does', () {
      expect(installKind(null, '1.0.0'), InstallKind.fresh);
      expect(installKind(_copy('0.9.0'), '1.0.0'), InstallKind.upgrade);
      expect(installKind(_copy('1.0.0'), '1.0.0'), InstallKind.reinstall);
      expect(installKind(_copy('1.1.0'), '1.0.0'), InstallKind.downgrade);
      expect(installKind(_copy(null), '1.0.0'), InstallKind.unknownVersion);
    });
  });

  testWidgets('a fresh install chooses its folder; nothing warns', (t) async {
    final f = await _pump(t);
    expect(find.text(_s.installTitle('TwimShelf')), findsOneWidget);
    expect(find.byKey(const ValueKey('installedNotice')), findsNothing);
    expect(find.text(_s.change), findsOneWidget);
    expect(find.text(_s.perUser), findsOneWidget);
    await _go(t);
    expect(f.installedTo, _folder);
    expect(f.shortcut, isFalse);
    expect(find.text(_s.installed('TwimShelf')), findsOneWidget);
  });

  testWidgets('an older copy offers the upgrade, in its own folder', (t) async {
    final f = await _pump(t, copy: _copy('0.1.0'), desktop: true);
    expect(find.text(_s.upgradeTitle('TwimShelf')), findsOneWidget);
    expect(find.text(_s.upgradeNotice('v0.1.0', 'v0.2.0')), findsOneWidget);
    expect(find.text('v0.1.0 → v0.2.0'), findsOneWidget);
    expect(find.text(_s.keepsData), findsOneWidget);
    expect(find.text(_s.upgrade), findsOneWidget);
    expect(find.text(_s.change), findsNothing);
    await _go(t);
    expect(f.installedTo, r'D:\Apps\TwimShelf');
    expect(f.shortcut, isTrue, reason: 'the desktop shortcut that is there stays');
    expect(find.text(_s.upgraded('TwimShelf', 'v0.2.0')), findsOneWidget);
  });

  testWidgets('the same version offers to overwrite', (t) async {
    await _pump(t, copy: _copy('0.2.0'));
    expect(find.text(_s.overwriteTitle('TwimShelf')), findsOneWidget);
    expect(find.text(_s.reinstallNotice('v0.2.0')), findsOneWidget);
    expect(find.text(_s.overwrite), findsOneWidget);
  });

  testWidgets('a newer copy warns, and does not promise the data is fine', (t) async {
    await _pump(t, copy: _copy('0.3.0'));
    expect(find.text(_s.downgradeNotice('v0.3.0', 'v0.2.0')), findsOneWidget);
    expect(find.text(_s.keepsData), findsNothing);
    expect(find.text(_s.overwrite), findsOneWidget);
  });

  testWidgets('a copy of unknown version offers to overwrite', (t) async {
    await _pump(t, copy: _copy(null));
    expect(find.text(_s.unknownNotice('v0.2.0')), findsOneWidget);
  });

  testWidgets('a failure shows why and can be tried again', (t) async {
    final f = await _pump(t, failures: 1);
    await _go(t);
    expect(find.textContaining('synthetic: file in use'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('retry')));
    await t.pump();
    await t.pump();
    expect(f.runs, 2);
    expect(find.text(_s.installed('TwimShelf')), findsOneWidget);
  });

  group('uninstall', () {
    testWidgets('keeps the data by default and says where it is', (t) async {
      final f = await _pump(t, mode: Mode.uninstall, copy: _copy('0.2.0'), data: _data);
      expect(find.text(_s.dataKeptNote), findsOneWidget);
      await _go(t);
      expect(f.removedData, isNull);
      expect(find.text(_s.dataKept), findsOneWidget);
      expect(find.text(_data), findsOneWidget);
    });
    testWidgets('deletes the data only when ticked', (t) async {
      final f = await _pump(t, mode: Mode.uninstall, copy: _copy('0.2.0'), data: _data);
      await t.tap(find.byKey(const ValueKey('removeData')));
      await t.pump();
      await _go(t);
      expect(f.removedData, _data);
      expect(find.text(_s.dataRemoved), findsOneWidget);
    });
    testWidgets('without a data folder there is nothing to offer', (t) async {
      await _pump(t, mode: Mode.uninstall, copy: _copy('0.2.0'));
      expect(find.byKey(const ValueKey('removeData')), findsNothing);
    });
  });

  testWidgets('every language has every text', (t) async {
    for (final l in const [Locale('en'), Locale('ja'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')]) {
      final s = S.of(l);
      for (final text in [s.upgradeTitle('A'), s.overwriteTitle('A'), s.keepsData, s.upgradeNotice('1', '2'), s.reinstallNotice('1'), s.downgradeNotice('1', '2'), s.unknownNotice('1'), s.closesRunning('A'), s.upgrading('A'), s.overwriting('A'), s.upgraded('A', '2'), s.upgrade, s.overwrite, s.installedFolder, s.dataKeptNote, s.dataRemoved, s.dataKept, s.retry, s.finish, s.installBody]) {
        expect(text, isNot(contains('%s')));
      }
    }
  });
}
