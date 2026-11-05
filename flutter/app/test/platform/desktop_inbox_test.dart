import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/platform/share_inbox.dart';
import 'package:twimshelf/platform/desktop_inbox.dart';
import 'package:twimshelf/platform/desktop_entry.dart';
import 'package:twimshelf/app/identity.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'argument grammar handles multiple, repeated, equals and literal paths',
    () {
      expect(parseDesktopImportArguments(['--verbose']), isEmpty);
      expect(
        parseDesktopImportArguments([
          '--import',
          'a',
          'b',
          '--import=c',
          '--',
          '--d',
        ]),
        ['a', 'b', 'c', '--d'],
      );
      for (final args in [
        ['--import'],
        ['--import='],
        ['--import', 'a', '--unknown'],
        ['--import', '\u0000'],
      ]) {
        expect(() => parseDesktopImportArguments(args), throwsFormatException);
      }
    },
  );
  test('relative, file URI, drive and UNC paths resolve in sender cwd', () {
    expect(
      resolveDesktopPath('a.jpg', '/tmp/sender', windows: false),
      '/tmp/sender/a.jpg',
    );
    expect(
      resolveDesktopPath('file:///tmp/a%20b.jpg', '/tmp', windows: false),
      '/tmp/a b.jpg',
    );
    expect(
      resolveDesktopPath(r'C:\Media\a.jpg', r'D:\Sender', windows: true),
      r'C:\Media\a.jpg',
    );
    expect(
      resolveDesktopPath(r'\\server\share\a.jpg', r'D:\Sender', windows: true),
      r'\\server\share\a.jpg',
    );
    expect(
      () => resolveDesktopPath('https://example.com/a', '/tmp'),
      throwsFormatException,
    );
  });
  test(
    'desktop Exec quotes shell metacharacters and registers no protocol',
    () {
      final text = desktopEntry('/tmp/a "b"\$`%/app', {
        'en': 'EN',
        'ja': 'JA',
        'zh-Hans': 'CN',
        'zh-Hant': 'TW',
      });
      expect(text, contains(r'Exec="/tmp/a \\"b\\"\\$\\`%%/app" --import %F'));
      expect(text, contains('Name[zh_TW]=TW'));
      expect(text, contains('video/mp4;'));
      expect(text, contains('Icon=$desktopId\n'));
      expect(text, contains('StartupWMClass=$desktopId\n'));
      final debug = desktopEntry(
        '/tmp/app',
        {'en': 'EN', 'ja': 'JA', 'zh-Hans': 'CN', 'zh-Hant': 'TW'},
        applicationId: 'org.twimshelf.debug',
        icon: '/tmp/a b/icon.png',
      );
      expect(debug, contains('Icon=/tmp/a b/icon.png\n'));
      expect(debug, contains('StartupWMClass=org.twimshelf.debug\n'));
      expect(text, isNot(contains('x-scheme-handler')));
      expect(
        () => desktopEntry('/tmp/\nbad', {'en': 'E'}),
        throwsArgumentError,
      );
    },
  );
  test(
    'watchers ignore partial writes and deletes, including failed staging',
    () {
      expect(
        isDesktopPublication(
          FileSystemCreateEvent('/Inbox/a.partial', true),
          request: false,
        ),
        false,
      );
      expect(
        isDesktopPublication(
          FileSystemDeleteEvent('/Inbox/a', false),
          request: false,
        ),
        false,
      );
      expect(
        isDesktopPublication(
          FileSystemCreateEvent('/Inbox/a', true),
          request: false,
        ),
        true,
      );
      expect(
        isDesktopPublication(
          FileSystemMoveEvent('/Inbox/a.partial', true, '/Inbox/a'),
          request: false,
        ),
        true,
      );
      expect(
        isDesktopPublication(
          FileSystemCreateEvent('/Requests/a.partial', false),
          request: true,
        ),
        false,
      );
      expect(
        isDesktopPublication(
          FileSystemDeleteEvent('/Requests/a.json', false),
          request: true,
        ),
        false,
      );
      expect(
        isDesktopPublication(
          FileSystemMoveEvent('/Requests/a.partial', false, '/Requests/a.json'),
          request: true,
        ),
        true,
      );
    },
  );
  group('durable staging', () {
    late Directory temp;
    late Directory root;
    late DesktopInbox inbox;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('desktop-share-test-');
      root = Directory('${temp.path}/Shares');
      inbox = DesktopInbox(root);
    });
    tearDown(() async {
      await temp.delete(recursive: true);
    });
    Future<List<Directory>> batches() async =>
        Directory('${root.path}/Inbox')
            .list()
            .where((e) => e is Directory)
            .cast<Directory>()
            .toList();
    test(
      'mixed media and links publish flat batch; originals survive',
      () async {
        final source = File('${temp.path}/photo.jpg');
        await source.writeAsBytes([0xff, 0xd8, 0xff, 0xe0]);
        await inbox.enqueue([
          '--import',
          'photo.jpg',
          'https://x.com/alice/status/123',
        ], workingDirectory: temp.path);
        expect(await inbox.publishRequests(), 0);
        final batch = (await batches()).single;
        expect(
          await File('${batch.path}/0_photo.jpg').readAsBytes(),
          await source.readAsBytes(),
        );
        expect(
          jsonDecode(await File('${batch.path}/_links.json').readAsString()),
          ['https://x.com/alice/status/123'],
        );
        expect(await source.exists(), true);
        expect(await Directory('${root.path}/Requests').list().isEmpty, true);
      },
    );
    test(
      'shell requests emit the existing file and durable link events',
      () async {
        await File('${temp.path}/a.jpg').writeAsString('a');
        final service = ShareInbox(
          root: root,
          importer: (source, keep, {folder, album = true}) async {
            expect(await File('$source/0_a.jpg').exists(), true);
            await Directory(source).delete(recursive: true);
            return ImportReport(posts: 0, media: 1);
          },
        );
        final events = <ShareInboxEvent>[];
        final subscription = service.events.listen(events.add);
        await service.importArguments([
          '--import',
          'a.jpg',
          'https://x.com/a/status/1',
        ], workingDirectory: temp.path);
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<ShareFilesImported>().single.report.media, 1);
        final link = events.whereType<ShareLinksReady>().single;
        expect(link.links, ['https://x.com/a/status/1']);
        await service.acknowledgeLinks(link.id);
        expect(await Directory('${root.path}/Links').list().isEmpty, true);
        expect(await File('${temp.path}/a.jpg').exists(), true);
        await subscription.cancel();
        await service.dispose();
      },
    );
    test('unsupported, missing and symlink inputs retain requests without publication', () async {
      final source = File('${temp.path}/a.jpg');
      await source.writeAsString('image');
      await Link('${temp.path}/link.jpg').create(source.path);
      for (final name in ['missing.jpg', 'bad.txt', 'link.jpg']) {
        if (name == 'bad.txt') {
          await File('${temp.path}/bad.txt').writeAsString('text');
        }
        await inbox.enqueue(['--import', name], workingDirectory: temp.path);
      }
      expect(await inbox.publishRequests(), 3);
      expect(await Directory('${root.path}/Requests').list().length, 3);
      expect(await batches(), isEmpty);
    });
    test('header-detected media receives an importable extension', () async {
      await File('${temp.path}/camera-file')
          .writeAsBytes([0xff, 0xd8, 0xff, 0xe0]);
      await inbox.enqueue([
        '--import',
        'camera-file',
      ], workingDirectory: temp.path);
      expect(await inbox.publishRequests(), 0);
      final batch = (await batches()).single;
      expect(await File('${batch.path}/0_camera-file.jpg').exists(), true);
    });
    test(
      'all-or-nothing batch retry succeeds after missing file restored',
      () async {
        await inbox.enqueue([
          '--import',
          'a.jpg',
          'b.mp4',
        ], workingDirectory: temp.path);
        await File('${temp.path}/a.jpg').writeAsString('a');
        expect(await inbox.publishRequests(), 1);
        expect(await batches(), isEmpty);
        await File('${temp.path}/b.mp4').writeAsString('b');
        expect(await inbox.publishRequests(), 0);
        expect((await batches()).length, 1);
      },
    );
    test('receipt prevents replay after consumed inbox; published batch recovers crash', () async {
      final requests = await Directory('${root.path}/Requests')
          .create(recursive: true);
      final request = File('${requests.path}/stable.json');
      const contents =
          '{"version":1,"arguments":["--import","https://x.com/a/status/1"],"workingDirectory":"/tmp"}';
      await request.writeAsString(contents);
      final batch = await Directory('${root.path}/Inbox/stable')
          .create(recursive: true);
      await File('${batch.path}/_links.json')
          .writeAsString('["https://x.com/a/status/1"]');
      expect(await inbox.publishRequests(), 0);
      await batch.delete(recursive: true);
      await request.writeAsString(contents);
      expect(await inbox.publishRequests(), 0);
      expect(await batches(), isEmpty);
    });
    test(
      'bad request does not block another and partial files remain invisible',
      () async {
        final requests = await Directory('${root.path}/Requests')
            .create(recursive: true);
        await File('${requests.path}/bad.json').writeAsString('{}');
        await File('${requests.path}/writing.partial').writeAsString('{}');
        await inbox.enqueue(['--import', 'https://x.com/a/status/1']);
        expect(await inbox.publishRequests(), 1);
        expect((await batches()).length, 1);
        expect(await File('${requests.path}/writing.partial').exists(), true);
      },
    );
  });
}
