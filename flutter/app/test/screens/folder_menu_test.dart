import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/folders_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
  });

  Future<void> pump(WidgetTester t) async {
    final library = LibraryModel.forTest('/no/such/folder')
      ..folders = FolderOverview(folders: [Folder(name: '猫', count: 3, videos: 0, cover_video: false)], photos: 3, videos: 0);
    await t.pumpWidget(MaterialApp(home: FoldersPage(library: library, onOpen: (_) {})));
    await t.pump();
  }

  void expectMenu() {
    for (final k in ['reveal', 'export', 'rename', 'delete']) {
      expect(find.byKey(ValueKey('folderMenu-$k')), findsOneWidget);
    }
  }

  testWidgets('a long press on a folder offers its actions', (t) async {
    await pump(t);
    await t.longPress(find.byKey(const ValueKey('folder-猫')));
    await t.pumpAndSettle();
    expectMenu();
  });

  testWidgets('a right click on a folder too', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('folder-猫')), buttons: kSecondaryButton);
    await t.pumpAndSettle();
    expectMenu();
  });
}
