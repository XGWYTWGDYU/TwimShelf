import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/actions/quick_download.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/share_inbox.dart';
import 'package:twimshelf/screens/share_sheet.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(locale: const Locale('zh', 'CN'));
  });

  group('the quick download card stays on the screen', () {
    const phone = Size(393, 852);
    test('under a button in the middle of a phone\'s row: wholly on the screen', () {
      final p = quickDownloadPlace(const Rect.fromLTWH(300, 60, 40, 40), phone);
      expect(p.left, 12);
      expect(p.width, 369);
      expect(p.left + p.width, lessThanOrEqualTo(phone.width - 12));
      expect(p.top, 106);
    });
    test('on a wide window: 380 wide, its right edge at the button\'s', () {
      final p = quickDownloadPlace(const Rect.fromLTWH(1000, 20, 40, 40), const Size(1200, 800));
      expect(p.width, 380);
      expect(p.left + p.width, 1040);
    });
    test('a button at the very edge does not push it off', () {
      final p = quickDownloadPlace(const Rect.fromLTWH(1190, 20, 40, 40), const Size(1200, 800));
      expect(p.left + p.width, 1188);
    });
  });

  testWidgets('one media has no count; many take rows, the last saying how many more', (t) async {
    List<({String path, bool video})> media(int n) => [for (var i = 0; i < n; i++) (path: '/no/such/$i.jpg', video: false)];
    Widget grid(int n) => MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 320, child: ShareThumbGrid(media: media(n))))));
    await t.pumpWidget(grid(4));
    expect(find.byKey(const ValueKey('shareCount')), findsNothing);
    await t.pumpWidget(grid(4));
    final few = t.getSize(find.byType(ShareThumbGrid)).height;
    await t.pumpWidget(grid(8));
    await t.pump();
    expect(t.getSize(find.byType(ShareThumbGrid)).height, greaterThan(few), reason: 'as tall as what it shows');
    await t.pumpWidget(grid(11));
    await t.pump();
    expect(find.text('+4'), findsOneWidget);
  });

  group('the inbox asks first', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('tl_share_ask'));
    tearDown(() => root.deleteSync(recursive: true));

    Directory batch(String id, Map<String, String> files) {
      final d = Directory('${root.path}/Inbox/$id')..createSync(recursive: true);
      files.forEach((k, v) => File('${d.path}/$k').writeAsStringSync(v));
      return d;
    }

    testWidgets('unconfirmed: announced once, nothing imported; discard removes it', (t) async {
      await t.runAsync(() async {
        final imported = <String>[];
        final inbox = ShareInbox(root: root, asks: true, importer: (p, k, {folder, album = true}) async => throw StateError('imported $p'));
        final events = <ShareInboxEvent>[];
        inbox.events.listen(events.add);
        final d = batch('share-1', {'a.jpg': 'x', '_links.json': '["https://x.com/synthetic/status/1"]'});
        await inbox.drain();
        await inbox.drain();
        final asked = events.whereType<ShareNeedsChoice>().toList();
        expect(asked.length, 1);
        expect(asked.single.files.single, endsWith('a.jpg'));
        expect(asked.single.links, ['https://x.com/synthetic/status/1']);
        expect(imported, isEmpty);
        expect(d.existsSync(), isTrue);
        await inbox.discard(asked.single);
        expect(d.existsSync(), isFalse);
        await inbox.dispose();
      });
    });

    testWidgets('confirmed: imported into the folder chosen', (t) async {
      await t.runAsync(() async {
        String? into;
        final inbox = ShareInbox(root: root, asks: true, importer: (p, k, {folder, album = true}) async {
          into = folder;
          Directory(p).deleteSync(recursive: true);
          throw const FormatException('report not needed here');
        });
        final d = batch('share-2', {'a.jpg': 'x', '_share.json': '{"version":1,"folder":"","links":[]}'});
        await inbox.drain();
        expect(into, isNull);
        expect(d.existsSync(), isFalse);
        await inbox.dispose();
      });
    });
  });
}
