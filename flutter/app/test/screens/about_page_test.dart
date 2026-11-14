import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/search/suggestions.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/about_page.dart';
import 'package:twimshelf/screens/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
    PackageInfo.setMockInitialValues(appName: 'x', packageName: 'x', version: '1.0.0', buildNumber: '1', buildSignature: '');
  });

  testWidgets('the check, the log and the diagnostics come out after ten taps on the icon', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var exported = 0;
    await tester.pumpWidget(MaterialApp(home: AboutPage(onExportDiagnostics: () => exported++, logFile: '/no/such/file')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1.0.0'), findsOneWidget);
    for (var i = 0; i < 9; i++) {
      await tester.tap(find.byKey(const ValueKey('aboutIcon')));
      await tester.pump();
    }
    for (final hidden in ['aboutCheck', 'aboutIntegrity', 'aboutLog', 'exportDiagnostics']) {
      expect(find.byKey(ValueKey(hidden)), findsNothing);
    }
    await tester.tap(find.byKey(const ValueKey('aboutIcon')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('exportDiagnostics')));
    expect(exported, 1);
    for (final shown in ['aboutCheck', 'aboutIntegrity', 'aboutLog']) {
      expect(find.byKey(ValueKey(shown)), findsOneWidget);
    }

    // they are still there the next time the page opens
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: AboutPage(onExportDiagnostics: () {}, logFile: '/no/such/file')));
    await tester.pump();
    expect(find.byKey(const ValueKey('aboutLog')), findsOneWidget);

    // ten more taps put them away
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const ValueKey('aboutIcon')));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('aboutLog')), findsNothing);
  });

  testWidgets('a section is a list of pieces: large corners only outside', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsSection(children: const [ListTile(title: Text('a')), ListTile(title: Text('b')), ListTile(title: Text('c'))])),
    ));
    BorderRadius corners(String t) {
      final m = tester.widget<Material>(find.ancestor(of: find.text(t), matching: find.byType(Material)).first);
      return (m.shape as RoundedRectangleBorder).borderRadius as BorderRadius;
    }
    expect(corners('a').topLeft.x, 18);
    expect(corners('a').bottomLeft.x, 4);
    expect(corners('b').topLeft.x, 4);
    expect(corners('b').bottomLeft.x, 4);
    expect(corners('c').bottomLeft.x, 18);
    final gap = tester.getTopLeft(find.text('b')).dy - tester.getTopLeft(find.text('a')).dy;
    expect(gap, greaterThan(tester.getSize(find.byType(ListTile).first).height));
  });

  test('损坏或丢失 and the search word 损坏 go with the maintenance rows', () {
    final prefs = Prefs.instance;
    List<String> offered(bool extras) => suggestionSections('', [], [], [], offerDamaged: extras)
        .expand((s) => s.rows)
        .map((i) => i.id)
        .toList();
    prefs.aboutExtras = false;
    expect(Place.offered, isNot(contains(Place.bad)));
    expect(offered(prefs.aboutExtras).any((id) => id.contains('damaged')), isFalse);
    prefs.aboutExtras = true;
    expect(Place.offered, contains(Place.bad));
    expect(offered(prefs.aboutExtras).any((id) => id.contains('damaged')), isTrue);
    prefs.aboutExtras = false;
  });

  test('按帖子分组 is remembered', () async {
    Prefs.instance.feedGrouped = false;
    await Prefs.load();
    expect(Prefs.instance.feedGrouped, isFalse);
    Prefs.instance.feedGrouped = true;
  });

  test('every colour offered has its name in the catalog, and sets differ', () {
    for (final name in seedColors.keys) {
      expect(L('appearance.color.$name'), isNot('appearance.color.$name'));
    }
    expect(seedColors.values.map((c) => schemeOf(c, Brightness.light).primary).toSet(), hasLength(greaterThan(12)));
  });
}
