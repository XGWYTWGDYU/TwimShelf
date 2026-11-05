import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/mascot/mascot.dart';
import 'package:twimshelf/mascot/pet_layer.dart';

/// The mascot mode on the real core: the crab shows only in wide windows and only with the switch
/// on, takes taps only on itself, and the icons follow the switch.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> run(WidgetTester tester, Duration d) async {
    await tester.runAsync(() => Future<void>.delayed(d));
    await tester.pump();
  }

  testWidgets('wide windows only, taps only on the crab', (tester) async {
    await Prefs.load();
    final before = Prefs.instance.mascot;
    addTearDown(() => Prefs.instance.mascot = before);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    var below = 0;
    Prefs.instance.mascot = true;
    await tester.pumpWidget(MaterialApp(
      home: MascotPetLayer(child: GestureDetector(behavior: HitTestBehavior.opaque, onTapDown: (_) => below++, child: const SizedBox.expand())),
    ));
    await run(tester, const Duration(milliseconds: 200));
    final pet = find.byType(MascotPetLayer);
    expect(find.descendant(of: pet, matching: find.byType(RepaintBoundary)), findsWidgets);

    // the pointer shaken about, as a mouse would
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    for (var i = 0; i < 30; i++) {
      await mouse.moveTo(Offset(i.isEven ? 100 : 400, 200));
      await run(tester, const Duration(milliseconds: 20));
    }
    await mouse.removePointer();
    expect(tester.takeException(), isNull);

    // elsewhere a tap reaches the page; on the crab it does not
    await tester.tapAt(const Offset(100, 100), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(below, 1);

    // too small a window: no crab; the switch off: none either
    Prefs.instance.mascot = false;
    await tester.pump();
    await tester.tapAt(const Offset(970, 670));
    await tester.pump();
    expect(below, 2, reason: 'nothing over the page with the switch off');
  });

  testWidgets('icons follow the switch', (tester) async {
    await Prefs.load();
    final before = Prefs.instance.mascot;
    addTearDown(() => Prefs.instance.mascot = before);
    Prefs.instance.mascot = false;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MascotIcon('home', fallback: Icon(Icons.home)))));
    expect(find.byIcon(Icons.home), findsOneWidget);
    Prefs.instance.mascot = true;
    await tester.pump();
    expect(find.byIcon(Icons.home), findsNothing);
    expect(find.byType(ClawdIcon), findsOneWidget);
  });
}
