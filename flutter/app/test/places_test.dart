import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/app/shell.dart';
import 'package:twimshelf/l10n/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => L10n.load(locale: const Locale('zh', 'CN')));

  test('every place has its title in every language', () {
    final places = [Place.browse, ...Place.primary, ...Place.mediaKinds, ...Place.others];
    for (final lang in ['en', 'zh-Hans', 'zh-Hant', 'ja']) {
      final table = jsonDecode(File('assets/l10n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
      for (final p in places) {
        expect(table.containsKey('place.${p.id}'), isTrue, reason: '$lang place.${p.id}');
      }
    }
    expect(Place.folder('旅行').title, '旅行');
  });

  test('the layout follows the window, never the device', () {
    expect(ShellLayout.of(const Size(390, 844)), ShellLayout.bar); // phone
    expect(ShellLayout.of(const Size(466, 678)), ShellLayout.bar); // folded foldable
    expect(ShellLayout.of(const Size(844, 390)), ShellLayout.bar); // phone sideways (short)
    expect(ShellLayout.of(const Size(700, 1000)), ShellLayout.bar); // narrow tablet window
    expect(ShellLayout.of(const Size(951, 669)), ShellLayout.sidebar); // open foldable
    expect(ShellLayout.of(const Size(1280, 800)), ShellLayout.sidebar); // desktop window
  });

  test('grid places filter like the native ones', () {
    expect(Place.photos.filter?.kind?.wireValue, 'photo');
    expect(Place.folder('a').filter?.folder, 'a');
    expect(Place.browse.filter, isNull);
    expect(Place.trash.isGrid, isTrue);
  });
}
