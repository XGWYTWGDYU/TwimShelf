import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/apple_platform.dart';
import 'package:twimshelf/screens/browse_page.dart';

class _Library extends ChangeNotifier implements LibraryModel {
  _Library({this.items = const []});
  final List<FeedItem> items;
  @override
  final revision = 0;
  @override
  final shuffleRequest = ValueNotifier(0);
  @override
  final revealRequest = ValueNotifier<FeedItem?>(null);
  @override
  final filterRequest = ValueNotifier<FeedFilter?>(null);
  @override
  FolderOverview? folders;

  @override
  Future<List<FeedItem>> feed(FeedRequest request) async => items;

  @override
  void dispose() {
    shuffleRequest.dispose();
    revealRequest.dispose();
    filterRequest.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.load(locale: const Locale('zh', 'CN'));
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
  });

  Future<void> pumpBrowse(WidgetTester t, Size window, {Size? display, List<FeedItem> items = const []}) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = window;
    t.view.display.size = display ?? window;
    t.view.display.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(t.view.display.reset);
    addTearDown(() => ApplePlatform.instance.windowControls.value = Rect.zero);
    final library = _Library(items: items);
    addTearDown(library.dispose);
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: BrowsePage(library: library),
    ));
    await t.pumpAndSettle();
  }

  const downloadBtn = ValueKey('quickDownload');
  const sortBtn = ValueKey('sortByAdded');
  const magnifier = ValueKey('searchButton');
  const floatingSearch = ValueKey('floatingSearch');
  const header = ValueKey('browseHeader');

  testWidgets('portrait shows three buttons (no title), opens full-screen search, and returns', (t) async {
    await pumpBrowse(t, const Size(390, 750));
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    expect(find.byKey(floatingSearch), findsNothing);
    expect(find.byTooltip(L('sidebar.other')), findsNothing);
    expect(find.byKey(const ValueKey('browseActionPill')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('browseActionPill')), matching: find.byKey(downloadBtn)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('browseActionPill')), matching: find.byKey(sortBtn)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('browseActionPill')), matching: find.byKey(magnifier)), findsNothing);
    expect(find.byKey(magnifier), findsOneWidget);
    expect(find.byKey(const ValueKey('groupToggle')), findsNothing);

    final wasByAdded = Prefs.instance.feedByAdded;
    await t.tap(find.byKey(sortBtn));
    await t.pumpAndSettle();
    expect(Prefs.instance.feedByAdded, !wasByAdded);

    await t.tap(find.byKey(magnifier));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('searchScreen')), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    expect(find.byKey(downloadBtn), findsOneWidget);
    expect(find.byKey(sortBtn), findsOneWidget);
    expect(find.byKey(magnifier), findsOneWidget);
    expect(find.byKey(floatingSearch), findsNothing);
  });

  testWidgets('iPad landscape and portrait always keep the three buttons, no title', (t) async {
    await pumpBrowse(t, const Size(790, 570), display: const Size(1180, 820));
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    expect(find.byKey(downloadBtn), findsOneWidget);
    expect(find.byKey(sortBtn), findsOneWidget);
    expect(find.byKey(magnifier), findsOneWidget);

    t.view.physicalSize = const Size(570, 790);
    await t.pumpAndSettle();
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    expect(find.byKey(downloadBtn), findsOneWidget);
    expect(find.byKey(sortBtn), findsOneWidget);
    expect(find.byKey(magnifier), findsOneWidget);
  });

  testWidgets('landscape sidebar shows three buttons (no title), and inline search without groupToggle', (t) async {
    await pumpBrowse(t, const Size(1100, 760));
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    await t.tap(find.byKey(magnifier));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('searchScreen')), findsNothing);
    expect(find.byKey(const ValueKey('groupToggle')), findsNothing);

    t.view.physicalSize = const Size(790, 570);
    await t.pumpAndSettle();
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
    expect(find.byKey(downloadBtn), findsOneWidget);
    expect(find.byKey(sortBtn), findsOneWidget);
    expect(find.byKey(magnifier), findsOneWidget);
    t.view.physicalSize = const Size(1100, 760);
    await t.pumpAndSettle();
    expect(find.text(L('place.browse')), findsNothing);   // 浏览 shows no title
  });

  testWidgets('nothing is frosted behind the buttons, at the top or scrolled', (t) async {
    final items = List.generate(
      12,
      (i) => FeedItem(
        media_id: 'm$i',
        post_id: 'p$i',
        ordinal: 0,
        kind: MediaKind.photo,
        path: '/nonexistent/$i.jpg',
        width: 400,
        height: 500,
      ),
    );
    await pumpBrowse(t, const Size(390, 750), items: items);

    // nothing frosted behind the buttons, at the top or with cards under them
    expect(find.descendant(of: find.byKey(header), matching: find.byType(BackdropFilter)), findsNothing);
    await t.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(downloadBtn), findsOneWidget);
  });

  testWidgets('the three buttons clear iPadOS 26+ window controls', (t) async {
    ApplePlatform.instance.windowControls.value = const Rect.fromLTWH(0, 0, 80, 52);
    await pumpBrowse(t, const Size(700, 760), display: const Size(1180, 820));

    expect(t.getTopLeft(find.byKey(downloadBtn)).dy, greaterThanOrEqualTo(52));
    expect(t.getTopLeft(find.byKey(sortBtn)).dy, greaterThanOrEqualTo(52));
    expect(t.getTopLeft(find.byKey(magnifier)).dy, greaterThanOrEqualTo(52));
  });
}
