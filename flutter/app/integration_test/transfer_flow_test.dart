import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/l10n/l10n.dart';

/// Importing and exporting on a real device, with the core and a synthetic library: repeats, the
/// mark on what a share brought in, a media-only zip with its files at the root.
///   flutter test integration_test/transfer_flow_test.dart -d DEVICE
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory base;

  List<int> jpeg(int seed) => img.encodeJpg(img.Image(width: 64, height: 64)..clear(img.ColorRgb8(seed * 37 % 255, 90, 200)));
  int live([FeedFilter? f]) => Core.feed(FeedRequest(filter: f, fuzzy: false)).length;
  List<String> ids() => [for (final i in Core.feed(FeedRequest(fuzzy: false))) i.media_id];

  Future<Directory> share(String id, Map<String, List<int>> files) async {
    final dir = await Directory('${base.path}/in/$id').create(recursive: true);
    for (final e in files.entries) {
      await File('${dir.path}/${e.key}').writeAsBytes(e.value);
    }
    return dir;
  }

  setUpAll(() async {
    await L10n.load(locale: const Locale('zh', 'CN'));
    base = await Directory('${(await getTemporaryDirectory()).path}/tl-transfer-$pid').create(recursive: true);
    expect(Core.open('${base.path}/lib'), isTrue);
  });

  testWidgets('what a share brought in is marked; repeats inside and against the library stay one', (t) async {
    await t.runAsync(() async {
      final first = await share('a', {'1.jpg': jpeg(1), '2.jpg': jpeg(2), 'same.jpg': jpeg(1)});
      final r = await Core.importLooseDirAsync(first.path, consume: true);
      expect(r.new_media, 2, reason: 'the repeat inside the share');
      expect(live(), 2);
      expect(live(FeedFilter(album_only: true)), 2);
      expect(Core.feed(FeedRequest(fuzzy: false)).every((i) => i.album), isTrue);
      expect(await first.exists(), isFalse, reason: 'consumed');
      // partly known
      final second = await share('b', {'1.jpg': jpeg(1), '3.jpg': jpeg(3)});
      final again = await Core.importLooseDirAsync(second.path, consume: true);
      expect(again.new_media, 1);
      expect(live(), 3);
    });
  });

  testWidgets('a media-only zip has every file at its root, and comes back without a new media', (t) async {
    await t.runAsync(() async {
      final out = '${base.path}/TwimShelf 猫咪搜索结果.zip';
      final rep = await Core.exportMediaAsync(ids(), out, options: ExportOptions(tags: false, folders: false, media_only: true));
      expect(rep.media, 3);
      final names = ZipDecoder().decodeBytes(await File(out).readAsBytes()).files.map((f) => f.name).toList();
      expect(names, hasLength(3));
      expect(names.where((n) => n.contains('/')), isEmpty, reason: '$names');
      expect(names.toSet(), hasLength(3));
      final r = await Core.importLooseZipAsync(out);
      expect(r.new_media, 0);
      expect(live(), 3);
    });
  });

  testWidgets('a pack keeps tags, folders and the mark, into an empty library and into itself', (t) async {
    await t.runAsync(() async {
      final all = ids();
      Core.addTag('合成标签', all.first);
      await createFolderForTest('夹', all.take(2).toList());
      final pack = '${base.path}/all.tlpack';
      final rep = await Core.exportMediaAsync(all, pack, options: ExportOptions());
      expect(rep.media, 3);
      final same = await Core.importPackAsync(pack, '');
      expect(same.new_media, 0);
      expect(live(), 3);
      await Core.wipeAsync(includeModels: false);
      expect(live(), 0);
      final back = await Core.importPackAsync(pack, '');
      expect(back.new_media, 3);
      expect(live(), 3);
      expect(live(FeedFilter(album_only: true)), 3, reason: 'the mark came back');
      expect(live(FeedFilter(review: ReviewFilter.reviewed)), 1);
      expect(live(FeedFilter(review: ReviewFilter.unreviewed)), 2);
      expect(Core.folders().firstWhere((f) => f.name == '夹').count, 2);
    });
  });

  testWidgets('拷贝 puts a media file on the clipboard', (t) async {
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) return;
    await t.runAsync(() async {
      final path = Core.feed(FeedRequest(fuzzy: false)).first.path;
      await const MethodChannel('org.twimshelf/share_inbox').invokeMethod<void>('copyFile', path);
    });
  });
}

Future<void> createFolderForTest(String name, List<String> media) async {
  Core.addToFolder(Core.createFolder(name), media: media);
}
