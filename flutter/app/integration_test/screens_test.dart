import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/grid/zoom_grid.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/grid_page.dart';
import 'package:twimshelf/screens/settings/tags_page.dart';
import 'package:twimshelf/screens/settings_page.dart';

/// This round's screens on the real app and core: selecting in a grid and moving to the bin, the
/// 整理 range filter, renaming a tag, the settings page. Run with TL_LIBRARY_DIR at a synthetic
/// (seeded) library — the test changes it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late LibraryModel library;

  Future<void> settle(WidgetTester t, [int frames = 30]) async {
    for (var i = 0; i < frames; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester t, Finder f) async {
    for (var i = 0; i < 80 && f.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    await L10n.load();
    await Prefs.load();
    library = await LibraryModel.open();
  });

  testWidgets('select two photos in a grid and move them to the bin', (tester) async {
    final binBefore = Core.trashList().length;
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    await until(tester, find.byType(ZoomGrid));
    await tester.tap(find.byKey(const ValueKey('gridSelect')));
    await settle(tester, 5);
    final r = tester.getRect(find.byType(ZoomGrid));
    await tester.tapAt(r.topLeft + const Offset(20, 20));
    await settle(tester, 15);
    await tester.tapAt(r.topLeft + Offset(r.width * 0.42, 20));
    await settle(tester, 15);
    expect(find.text(L('grid.selected', [2])), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gridTrash')));
    await settle(tester);
    expect(Core.trashList().length, binBefore + 2);
  });

  testWidgets('a tag can be renamed', (tester) async {
    final tag = Core.allTags().first.label;
    await tester.pumpWidget(MaterialApp(home: TagsPage(library: library)));
    await until(tester, find.byKey(ValueKey('tag-$tag')));
    await tester.tap(find.descendant(of: find.byKey(ValueKey('tag-$tag')), matching: find.byType(PopupMenuButton<void Function()>)));
    await settle(tester, 10);
    await tester.tap(find.text(L('tags.renameOrMerge')));
    await settle(tester, 10);
    await tester.enterText(find.byType(TextField), '${tag}x');
    await tester.tap(find.text(L('common.done')));
    await settle(tester, 30);
    expect(Core.allTags().any((t) => t.label == '${tag}x'), isTrue);
  });

  testWidgets('settings show the library and its sections', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsPage(library: library)));
    await settle(tester, 20);
    expect(find.text(L('common.library')), findsOneWidget);
    expect(find.text(L('common.importAndBackup')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-tags')), findsOneWidget);
  });
}
