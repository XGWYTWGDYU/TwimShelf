import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/screens/settings/transfer_page.dart';

/// The page lives in one of the shell's own navigators, the dialog on the root one: when the work
/// ends the dialog goes, and nothing of the page's navigator goes with it.
void main() {
  testWidgets('the progress dialog closes from inside a nested navigator', (tester) async {
    late BuildContext page;
    await tester.pumpWidget(MaterialApp(
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Text('first')),
      ),
    ));
    final nested = tester.state<NavigatorState>(find.byType(Navigator).last);
    unawaited(nested.push(MaterialPageRoute<void>(builder: (c) {
      page = c;
      return const Text('transfer');
    })));
    await tester.pumpAndSettle();

    final work = Completer<int>();
    final result = TransferPage.withProgress<int>(page, 'importing', work.future, () async => null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('importing'), findsOneWidget);

    work.complete(7);
    expect(await result, 7);
    await tester.pumpAndSettle();
    expect(find.text('importing'), findsNothing, reason: 'nothing left behind the result');
    expect(find.text('transfer'), findsOneWidget, reason: 'the page stays');
  });
}
