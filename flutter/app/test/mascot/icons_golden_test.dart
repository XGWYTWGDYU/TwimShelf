import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/mascot/clawd_icons.g.dart';
import 'package:twimshelf/mascot/mascot.dart';

/// Every mascot icon parses and draws (`--update-goldens` writes a sheet to look at).
void main() {
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
