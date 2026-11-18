import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/mascot/clawd_icons.g.dart';
import 'package:twimshelf/mascot/mascot.dart';

/// Every mascot icon parses and draws (`--update-goldens` writes a sheet to look at).
void main() {
  testWidgets('navigation shows the mascot briefly only after activation', (tester) async {
    SharedPreferences.setMockInitialValues({'mascot.enabled': true});
    await Prefs.load();
    var activations = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MascotPress(
      'home',
      onPressed: () => activations++,
      builder: (context, mascot, press) => IconButton(
        onPressed: press,
        icon: MascotIcon(mascot, fallback: const Icon(Icons.home)),
      ),
    ))));

    expect(find.byIcon(Icons.home), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(activations, 1);
    expect(find.byType(ClawdIcon), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.home), findsOneWidget);
    expect(find.byType(ClawdIcon), findsNothing);

    Prefs.instance.mascot = false;
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(activations, 2);
    expect(find.byType(ClawdIcon), findsNothing);
  });

  testWidgets('the mascot icons draw', (tester) async {
    tester.view.physicalSize = const Size(800, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('sheet'),
          child: Wrap(children: [
            for (final name in clawdIcons.keys) Padding(padding: const EdgeInsets.all(8), child: ClawdIcon(name, size: 96, color: Colors.black87)),
            for (final name in clawdIcons.keys) Padding(padding: const EdgeInsets.all(4), child: ClawdIcon(name, size: 24, color: Colors.black87)),
          ]),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(ClawdIcon), findsNWidgets(clawdIcons.length * 2));
    if (autoUpdateGoldenFiles) await expectLater(find.byKey(const ValueKey('sheet')), matchesGoldenFile('icons_sheet.png'));
  });
}
