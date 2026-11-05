import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/sync_page.dart';

/// 局域网同步 on the real core: create an account, show a pairing code, leave again. Run with
/// TL_LIBRARY_DIR at a synthetic library; a debug build advertises only `_twlib-debug._tcp`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(WidgetTester t, Finder f) async {
    for (var i = 0; i < 80 && f.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('create, show a code, leave', (tester) async {
    await L10n.load();
    await Prefs.load();
    final library = await LibraryModel.open();
    final sync = library.sync;
    await sync.start();
    if (sync.joined) await sync.leave();
    await tester.pumpWidget(MaterialApp(home: SyncPage(sync: sync, onDeleteEverything: () async {})));
    await until(tester, find.byKey(const ValueKey('sync-create')));
    await tester.tap(find.byKey(const ValueKey('sync-create')));
    await until(tester, find.byKey(const ValueKey('sync-show-code')));
    expect(sync.joined, isTrue);
    expect(sync.status?.account_id, isNotNull);
    expect(sync.discovery?.running, isTrue);

    await tester.tap(find.byKey(const ValueKey('sync-show-code')));
    await until(tester, find.byKey(const ValueKey('sync-code')));
    final code = tester.widget<SelectableText>(find.byKey(const ValueKey('sync-code'))).data!;
    expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue, reason: code);
    await tester.tap(find.text(L('common.done')));
    await tester.pump(const Duration(milliseconds: 300));

    final leave = find.byKey(const ValueKey('sync-leave'));
    await tester.scrollUntilVisible(leave, 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(leave);
    await until(tester, find.text(L('sync.leave.confirm')));
    await tester.tap(find.text(L('sync.leave.confirm')));
    await until(tester, find.byKey(const ValueKey('sync-create')));
    expect(sync.joined, isFalse);
  });
}
