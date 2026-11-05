import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/platform/share_inbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('post link validation accepts core forms and deduplicates', () {
    expect(
      parseSharedPostLinks(
        'See https://X.COM/a_b/status/123?s=20 '
        'mobile.twitter.com/a/statuses/9/photo/1 '
        'https://fxtwitter.com/i/web/status/44 '
        'https://x.com/a_b/status/123',
      ),
      [
        'https://x.com/a_b/status/123',
        'https://x.com/a/status/9',
        'https://x.com/i/status/44',
      ],
    );
  });
  test('rejects websites, profile links, spoofed hosts and invalid ids', () {
    for (final value in [
      'https://evilx.com/a/status/1',
      'https://x.com.evil.org/a/status/1',
      'https://x.com/a/likes',
      'https://x.com/../status/1',
      'https://x.com/a/status/123456789012345678901',
      'https://evil.org/x.com/a/status/1',
      'https://x.com:8080/a/status/1',
      'https://x.com/a/status/',
      'https://x.com/%FF/status/1',
    ]) {
      expect(parseSharedPostLinks(value), isEmpty, reason: value);
    }
  });
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('share-inbox-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<Directory> batch(String id) =>
      Directory('${root.path}/Inbox/$id').create(recursive: true);

  test(
    'links survive restart until acknowledged; invalid ids cannot escape',
    () async {
      final source = await batch('share-1');
      await File('${source.path}/_links.json')
          .writeAsString(jsonEncode(['https://x.com/a/status/1']));
      final events = <ShareInboxEvent>[];
      var inbox = ShareInbox(root: root);
      var subscription = inbox.events.listen(events.add);
      await inbox.start();
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<ShareLinksReady>());
      expect(await source.exists(), isFalse);
      await subscription.cancel();
      await inbox.dispose();
      events.clear();
      inbox = ShareInbox(root: root);
      subscription = inbox.events.listen(events.add);
      await inbox.start();
      await Future<void>.delayed(Duration.zero);
      expect((events.single as ShareLinksReady).links, [
        'https://x.com/a/status/1',
      ]);
      await expectLater(
        inbox.acknowledgeLinks('../outside'),
        throwsArgumentError,
      );
      await inbox.acknowledgeLinks('share-1');
      events.clear();
      await inbox.drain();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await subscription.cancel();
      await inbox.dispose();
    },
  );
  test(
    'files import once; concurrent drains serialize; fresh partial is ignored',
    () async {
      final source = await batch('share-2');
      await File('${source.path}/photo.png').writeAsBytes([1, 2, 3]);
      final partial = await batch('share-3.partial');
      var calls = 0;
      final events = <ShareInboxEvent>[];
      final inbox = ShareInbox(
        root: root,
        importer: (path, kept, {folder, album = true}) async {
          calls++;
          // Windows lists with its own separator
          expect(path.replaceAll(r'\', '/'), source.path.replaceAll(r'\', '/'));
          expect(kept, '${root.path}/Kept/share-2');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await Directory(path).delete(recursive: true);
          return ImportReport(posts: 0, media: 1);
        },
      );
      final subscription = inbox.events.listen(events.add);
      await Future.wait([inbox.start(), inbox.drain(), inbox.drain()]);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(events.single, isA<ShareFilesImported>());
      expect(await partial.exists(), isTrue);
      await subscription.cancel();
      await inbox.dispose();
    },
  );
  test('failure preserves share for next resume, without retry loop', () async {
    final source = await batch('share-4');
    await File('${source.path}/photo.png').writeAsBytes([1]);
    var calls = 0;
    final events = <ShareInboxEvent>[];
    final inbox = ShareInbox(
      root: root,
      importer: (path, kept, {folder, album = true}) async {
        calls++;
        if (calls == 1) throw StateError('synthetic failure');
        await Directory(path).delete(recursive: true);
        return ImportReport(posts: 0, media: 1);
      },
    );
    final subscription = inbox.events.listen(events.add);
    await inbox.start();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(await source.exists(), isTrue);
    expect(events.single, isA<ShareInboxFailure>());
    inbox.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await inbox.drain();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(await source.exists(), isFalse);
    expect(events.last, isA<ShareFilesImported>());
    await subscription.cancel();
    await inbox.dispose();
  });
  test('symlinks cannot import files outside the inbox', () async {
    final source = await batch('share-5');
    final outside = File('${root.path}/outside.png');
    await outside.writeAsBytes([1]);
    await Link('${source.path}/photo.png').create(outside.path);
    var calls = 0;
    final events = <ShareInboxEvent>[];
    final inbox = ShareInbox(
      root: root,
      importer: (path, kept, {folder, album = true}) async {
        calls++;
        return ImportReport(posts: 0, media: 0);
      },
    );
    final subscription = inbox.events.listen(events.add);
    await inbox.start();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    expect(events.single, isA<ShareInboxFailure>());
    expect(await outside.readAsBytes(), [1]);
    await subscription.cancel();
    await inbox.dispose();
  });
}
