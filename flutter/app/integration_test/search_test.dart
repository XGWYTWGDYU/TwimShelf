import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/downloads_page.dart';
import 'package:twimshelf/screens/browse_page.dart';
import 'package:twimshelf/search/query.dart';

/// The capsule search in 浏览 and the 下载帖子 page, on a synthetic library (TL_LIBRARY_DIR).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late LibraryModel library;

  Future<void> until(WidgetTester t, bool Function() ok) async {
    for (var i = 0; i < 80 && !ok(); i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    await L10n.load();
    await Prefs.load();
    library = await LibraryModel.open();
  });

  testWidgets('a finished word becomes a capsule; a contradiction finds nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(home: BrowsePage(library: library)));
    final field = find.byKey(const ValueKey('search'));
    await until(tester, () => field.evaluate().isNotEmpty);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 300));
    // typing a keyword's start suggests it
    final video0 = SearchKeyword.video.word;
    await tester.enterText(field, video0.substring(0, 1));
    await until(tester, () => find.byKey(const ValueKey('suggest-keyword-video')).evaluate().isNotEmpty || find.text(video0).evaluate().isNotEmpty);
    expect(find.text(video0), findsWidgets);

    final video = SearchKeyword.video.word;
    await tester.enterText(field, '$video ');
    await until(tester, () => find.byKey(const ValueKey('capsule-k:video')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('capsule-k:video')), findsOneWidget);

    // typed after the invisible mark that stands before the cursor while there are capsules
    await tester.enterText(field, '\u200B-$video ');
    await until(tester, () => find.text(L('feed.empty.noMatch')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('capsule--k:video')), findsOneWidget);
    expect(find.text(L('feed.empty.noMatch')), findsOneWidget);

    // deleting in the empty field takes the last capsule away (an on-screen keyboard deletes
    // the invisible mark before the cursor)
    await tester.enterText(field, '');
    await until(tester, () => find.byKey(const ValueKey('capsule--k:video')).evaluate().isEmpty);
    expect(find.byKey(const ValueKey('capsule--k:video')), findsNothing);
    expect(find.byKey(const ValueKey('capsule-k:video')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('searchClear')));
    await until(tester, () => find.byKey(const ValueKey('capsule-k:video')).evaluate().isEmpty);
    expect(find.byKey(const ValueKey('capsule-k:video')), findsNothing);
  });

  testWidgets('the download page refuses a line that is not a post link', (tester) async {
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(downloads: library.downloads)));
    await tester.enterText(find.byKey(const ValueKey('download-links')), 'not a link');
    await tester.tap(find.byKey(const ValueKey('download-start')));
    await until(tester, () => find.text(L('settings.links.unrecognized')).evaluate().isNotEmpty);
    expect(find.text(L('settings.links.unrecognized')), findsWidgets);
    expect(library.downloads.queue, isEmpty);
  });
}
