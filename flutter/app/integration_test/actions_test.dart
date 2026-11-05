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
import 'package:twimshelf/screens/browse_page.dart';

/// The card's "+" adds a tag through the picker, and a grid's long press offers the native
/// menu (with 在浏览中查看帖子). Run with TL_LIBRARY_DIR at a synthetic (seeded) library.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late LibraryModel library;

  Future<void> settle(WidgetTester t, [int frames = 30]) async {
    for (var i = 0; i < frames; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    await L10n.load();
    await Prefs.load();
    library = await LibraryModel.open();
  });

  testWidgets('the + on a card adds a tag', (tester) async {
    await tester.pumpWidget(MaterialApp(home: BrowsePage(library: library)));
    for (var i = 0; i < 60 && find.byKey(const ValueKey('addTag')).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // into the middle of the screen (the top edge is under the floating search area)
    await Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('addTag')).first), alignment: 0.5);
    await settle(tester, 10);
    await tester.tap(find.byKey(const ValueKey('addTag')).first);
    await settle(tester, 40);
    expect(find.byKey(const ValueKey('tagPickerField')), findsOneWidget);
    final label = 'it${DateTime.now().millisecondsSinceEpoch % 100000}';
    await tester.enterText(find.byKey(const ValueKey('tagPickerField')), label);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text(L('tagPicker.justAdded')), findsOneWidget);
    expect(Core.allTags().any((t) => t.label == label), isTrue, reason: 'the tag reached the library');
  });

  testWidgets('a long press in a grid opens the media menu', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 60 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final grid = tester.getRect(find.byType(ZoomGrid));
    await tester.longPressAt(grid.topLeft + const Offset(30, 30));
    await settle(tester);
    expect(find.byKey(const ValueKey('menu-reveal')), findsOneWidget);
    expect(find.text(L('common.addToFolder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-reveal')));
    await settle(tester, 5);
    expect(library.revealRequest.value, isNotNull, reason: 'asks the shell to show the post in 浏览');
  });
}
