import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/app/shell.dart';
import 'package:twimshelf/l10n/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
  });

  testWidgets('a capsule floating over the page: narrower than the screen, clear of its bottom, the page under it', (t) async {
    t.view.physicalSize = const Size(390, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Place? tapped;
    late double pageRoom;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        extendBody: true,
        body: Builder(builder: (c) {
          pageRoom = MediaQuery.paddingOf(c).bottom;
          return const SizedBox.expand();
        }),
        bottomNavigationBar: FloatingNavBar(places: Place.primary, current: Place.browse, onTap: (p) => tapped = p),
      ),
    ));
    await t.pumpAndSettle();
    final bar = t.getRect(find.byKey(const ValueKey('floatingBar')));
    expect(bar.width, lessThan(390));
    expect(bar.left, greaterThan(0));
    expect(800 - bar.bottom, greaterThanOrEqualTo(12));
    expect(pageRoom, greaterThanOrEqualTo(800 - bar.top), reason: 'lists keep what is last above the bar');
    expect(find.text(Place.browse.title), findsOneWidget, reason: 'the chosen place shows its name');
    expect(find.text(Place.settings.title), findsNothing);
    await t.tap(find.byKey(ValueKey('bar-${Place.settings.id}')));
    expect(tapped, Place.settings);
  });
}
