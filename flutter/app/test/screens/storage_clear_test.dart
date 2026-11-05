import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/screens/settings/storage_page.dart';
import 'package:twimshelf/screens/browse_page.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tl_storage_clear'));
  tearDown(() => root.deleteSync(recursive: true));

  File file(String name, {Duration age = Duration.zero}) {
    final f = File('${root.path}/$name')..createSync(recursive: true);
    f.writeAsStringSync('synthetic');
    if (age > Duration.zero) f.setLastModifiedSync(DateTime.now().subtract(age));
    return f;
  }

  test('thumbnails: the files go, the folders stay; other groups are not touched', () async {
    final thumb = file('thumbs/a/1.jpg');
    final cache = file('cache/old', age: const Duration(days: 2));
    final skipped = await clearStorageFiles({'thumbnails'}, {'thumbnails': ['${root.path}/thumbs'], 'cache': ['${root.path}/cache']}, recentReason: 'recent');
    expect(skipped, isEmpty);
    expect(thumb.existsSync(), isFalse);
    expect(Directory('${root.path}/thumbs/a').existsSync(), isTrue);
    expect(cache.existsSync(), isTrue);
  });

  test('cache: old entries go; those touched in the last hour stay and are reported', () async {
    final old = file('cache/old', age: const Duration(hours: 2));
    final recent = file('cache/recent');
    final single = file('single', age: const Duration(hours: 2));
    final skipped = await clearStorageFiles({'cache'}, {'cache': ['${root.path}/cache', single.path, '${root.path}/gone']}, recentReason: 'recent');
    expect(old.existsSync(), isFalse);
    expect(single.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    expect(File(skipped.single.path).absolute.uri, File(recent.path).absolute.uri);
    expect(skipped.single.reason, 'recent');
  });

  test('only clearable groups can be cleared', () async {
    final app = file('app/binary', age: const Duration(days: 2));
    expect(await clearStorageFiles({'app', 'photos'}, {'app': ['${root.path}/app'], 'photos': ['${root.path}/app']}, recentReason: 'recent'), isEmpty);
    expect(app.existsSync(), isTrue);
  });

  testWidgets('the button shrinks and fades out of its row, takes no taps, and comes back', (t) async {
    var taps = 0;
    Widget row(bool shown) => MaterialApp(
          home: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 10),
            CollapsingButton(
              shown: shown,
              child: IconButton(key: const ValueKey('b'), icon: const Icon(Icons.shuffle), onPressed: () => taps++),
            ),
          ]),
        );
    double width() => t.getSize(find.byType(CollapsingButton)).width;
    await t.pumpWidget(row(true));
    final full = width();
    expect(full, greaterThan(0));
    await t.tap(find.byKey(const ValueKey('b')));
    expect(taps, 1);

    await t.pumpWidget(row(false));
    await t.pump(const Duration(milliseconds: 130));
    expect(width(), inExclusiveRange(0, full), reason: 'halfway: an animation, not a jump');
    await t.pumpAndSettle();
    expect(width(), 0);
    await t.tap(find.byKey(const ValueKey('b'), skipOffstage: false), warnIfMissed: false);
    expect(taps, 1);

    await t.pumpWidget(row(true));
    await t.pump(const Duration(milliseconds: 130));
    expect(width(), inExclusiveRange(0, full));
    await t.pumpAndSettle();
    expect(width(), full);
  });
}
