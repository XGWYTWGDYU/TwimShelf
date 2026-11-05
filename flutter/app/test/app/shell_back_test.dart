import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/app/shell.dart';

void main() {
  testWidgets("the system's back leaves a subpage of the open place, and the app only from its first page", (t) async {
    var exits = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final place = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(
      home: ShellBackHandler(
        navigator: () => place.currentState,
        child: Navigator(key: place, onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const Text('settings'))),
      ),
    ));
    place.currentState!.push(MaterialPageRoute(builder: (_) => const Text('subpage')));
    await t.pumpAndSettle();
    expect(find.text('subpage'), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('settings'), findsOneWidget);
    expect(find.text('subpage'), findsNothing);
    expect(exits, 0);

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(exits, 1);
  });

  testWidgets('a SnackBar with an action still goes away by itself when told not to persist', (t) async {
    late BuildContext context;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => Text('x', key: Key('${context = c}'))))));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('toast'), persist: false, duration: const Duration(seconds: 2), action: SnackBarAction(label: 'a', onPressed: () {})));
    await t.pumpAndSettle();
    expect(find.text('toast'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('toast'), findsNothing);
  });

  test('every SnackBar with an action says it does not persist', () {
    for (final f in ['lib/actions/card_menu.dart', 'lib/actions/media_actions.dart']) {
      expect(File(f).readAsStringSync(), contains('persist: false'), reason: f);
    }
  });
}
