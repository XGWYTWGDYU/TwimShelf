import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/share_inbox.dart';

/// The share flow on a real device, with the core, its own synthetic library and its own inbox:
/// nothing arrives before it is confirmed, and it arrives in the folder chosen.
///   flutter test integration_test/share_flow_test.dart -d DEVICE
/// TL_LINK_TEST=1 (--dart-define) also downloads one public post.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ShareInbox inbox;
  final events = <ShareInboxEvent>[];

  int media() => Core.feed(FeedRequest()).length;
  int inFolder(String name) => Core.folders().where((f) => f.name == name).map((f) => f.count).firstOrNull ?? 0;

  Future<ShareNeedsChoice> arrive(String id, Map<String, List<int>> files) async {
    final dir = await Directory('${root.path}/Inbox/$id').create(recursive: true);
    for (final e in files.entries) {
      await File('${dir.path}/${e.key}').writeAsBytes(e.value);
    }
    events.clear();
    await inbox.drain();
    return events.whereType<ShareNeedsChoice>().single;
  }

  List<int> jpeg(int seed) => img.encodeJpg(img.Image(width: 64, height: 64)..clear(img.ColorRgb8(seed * 40 % 255, 90, 200 - seed)));

  setUpAll(() async {
    await L10n.load(locale: const Locale('zh', 'CN'));
    final base = await Directory('${(await getTemporaryDirectory()).path}/tl-share-flow-$pid').create(recursive: true);
    expect(Core.open('${base.path}/lib'), isTrue);
    root = await Directory('${base.path}/shares').create();
    inbox = ShareInbox(root: root, asks: true)..events.listen(events.add);
  });

  testWidgets('the app group the extension writes to is reachable', (t) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    final shares = await t.runAsync(TlNative.sharesRoot);
    expect(shares, isNotNull, reason: 'no app group: the extension and the app share nothing');
    final probe = File('$shares/probe');
    await t.runAsync(() async {
      await probe.parent.create(recursive: true);
      await probe.writeAsString('x');
      await probe.delete();
    });
    // ignore: avoid_print
    print('shares root ok: $shares');
  });

  testWidgets('closed: nothing arrives, nothing stays', (t) async {
    await t.runAsync(() async {
      final before = media();
      final batch = await arrive('share-closed', {'a.jpg': jpeg(1), 'b.jpg': jpeg(2)});
      expect(batch.files.length, 2);
      expect(media(), before);
      await inbox.discard(batch);
      expect(Directory(batch.directory).existsSync(), isFalse);
      await inbox.drain();
      expect(media(), before);
    });
  });

  testWidgets('confirmed with no folder, then with a new folder', (t) async {
    await t.runAsync(() async {
      final before = media();
      await inbox.confirm(await arrive('share-none', {'c.jpg': jpeg(3)}));
      expect(media(), before + 1);
      await inbox.confirm(await arrive('share-folder', {'d.jpg': jpeg(4), 'e.jpg': jpeg(5), 'f.jpg': jpeg(6)}), folder: '分享测试');
      expect(media(), before + 4);
      expect(inFolder('分享测试'), 3);
    });
  });

  testWidgets('a link: downloaded apart, closed leaves nothing, confirmed arrives in its folder', (t) async {
    if (!const bool.fromEnvironment('TL_LINK_TEST')) return;
    const link = 'https://x.com/example_user/status/1900000000000000001';
    await t.runAsync(() async {
      final before = media();
      final file = '["$link"]'.codeUnits;
      var batch = await arrive('share-link-closed', {'_links.json': file});
      expect(batch.links, [link]);
      var staged = await inbox.stage(batch.id, batch.links);
      expect(staged.failed, isEmpty);
      expect(staged.items, isNotEmpty);
      expect(media(), before, reason: 'the staging folder is not the library');
      await inbox.discard(batch);
      expect(media(), before);

      batch = await arrive('share-link', {'_links.json': file});
      staged = await inbox.stage(batch.id, batch.links);
      await inbox.confirm(batch, folder: '链接测试', staged: true);
      expect(media(), before + staged.items.length);
      expect(inFolder('链接测试'), staged.items.length);
    });
  });

  testWidgets('a share with a bad link says why, keeps the files', (t) async {
    await t.runAsync(() async {
      final batch = await arrive('share-mixed', {'g.jpg': jpeg(7)});
      final staged = await inbox.stage(batch.id, ['https://x.com/a/status/not-a-number']);
      expect(staged.items, isEmpty);
      expect(staged.failed.single.reason, isNotEmpty);
      await inbox.discard(batch);
    });
  });
}
