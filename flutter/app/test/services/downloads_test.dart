import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/services/downloads.dart';
import 'package:twimshelf/platform/share_inbox.dart';

class MemoryStore implements DownloadQueueStore {
  Map<String, dynamic>? saved;
  bool fail = false;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> read() async => saved == null
      ? null
      : jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
  @override
  Future<String?> setAside() async {
    saved = null;
    return 'set aside';
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    if (fail) throw const FileSystemException('synthetic storage failure');
    saved = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

DownloadStatus snapshot({
  bool running = false,
  int paused = 0,
  int generation = 1,
  String outcome = 'running',
  int total = 1,
  int done = 0,
}) => DownloadStatus(
  outcome: outcome,
  paused: paused,
  running: running,
  total: total,
  done: done,
  skipped: 0,
  failed: 0,
  active: const [],
  errors: const [],
  generation: generation,
  recent: const [],
);

class FakeCore implements DownloadCore {
  final starts = <DownloadRequest>[];
  final resumes = <DownloadRequest>[];
  final stops = <bool>[];
  List<String> bookmarkLinks = ['https://twitter.com/seed/status/2'];
  DownloadStatus? current;
  bool failStart = false;
  void Function()? afterStart;
  int polls = 0, cookies = 0;
  @override
  Future<int> start(DownloadRequest request) async {
    if (failStart) throw StateError('synthetic start failure');
    starts.add(request);
    current = snapshot(running: true, total: request.urls.length);
    afterStart?.call();
    return request.urls.length;
  }

  @override
  Future<int> stop(bool pause) async {
    stops.add(pause);
    current = snapshot(
      outcome: pause ? 'paused' : 'cancelled',
      paused: pause ? 1 : 0,
    );
    return 1;
  }

  @override
  Future<int> resume(DownloadRequest request) async {
    resumes.add(request);
    current = snapshot(running: true);
    return 1;
  }

  @override
  Future<DownloadStatus?> status() async {
    polls++;
    return current;
  }

  @override
  Future<List<String>> bookmarks(String path) async => bookmarkLinks;
  @override
  Future<void> applyCookies(DownloadRoute route) async {
    cookies++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCore core;
  late MemoryStore store;
  late DownloadService service;
  setUp(() async {
    core = FakeCore();
    store = MemoryStore();
    service = DownloadService(
      core: core,
      store: store,
      pollInterval: const Duration(days: 1),
    );
    await service.initialize();
  });
  tearDown(() async {
    await service.close();
  });
  test(
    'durable canonical queue survives restart and deduplicates post identities',
    () async {
      await service.enqueueLinks([
        'https://X.COM/seed/status/1?s=20',
        'https://fxtwitter.com/other/status/1',
        'Text https://x.com/seed/status/2',
      ]);
      expect(service.queue.map((e) => e.url), [
        'https://x.com/seed/status/1',
        'https://x.com/seed/status/2',
      ]);
      service.route = DownloadRoute.fx;
      service.concurrency = 5;
      service.intervalMs = 1200;
      service.folder = 'synthetic';
      await service.flush();
      await service.close();
      service = DownloadService(
        core: core,
        store: store,
        pollInterval: const Duration(days: 1),
      );
      await service.initialize();
      expect(service.queue.length, 2);
      expect(service.route, DownloadRoute.fx);
      expect(service.concurrency, 5);
      expect(service.intervalMs, 1200);
      expect(service.folder, 'synthetic');
      expect(core.starts, isEmpty);
      await service.start();
      expect(core.starts.single.route, DownloadRoute.fx);
      expect(service.queue, isEmpty);
      expect(service.status?.running, isTrue);
      expect(service.isPolling, isTrue);
    },
  );
  test('invalid batch fails before persisting any new link', () async {
    await expectLater(
      service.enqueueLinks(['https://x.com/s/status/1', 'https://evil.org/a']),
      throwsA(isA<DownloadServiceException>()),
    );
    expect(service.queue, isEmpty);
    expect(store.saved, isNull);
  });
  test('core start failure never removes links from the outbox', () async {
    await service.enqueueLinks(['https://x.com/s/status/1']);
    core.failStart = true;
    await expectLater(service.start(), throwsStateError);
    expect(service.queue.length, 1);
    expect((store.saved!['queue'] as List).length, 1);
    core.failStart = false;
    await service.start();
    expect(service.queue, isEmpty);
  });
  test(
    'failed post-handoff persistence retains outbox while core keeps ownership',
    () async {
      await service.enqueueLinks(['https://x.com/s/status/1']);
      core.afterStart = () => store.fail = true;
      await expectLater(service.start(), throwsA(isA<FileSystemException>()));
      expect(core.starts.length, 1);
      expect(service.queue.length, 1);
      expect((store.saved!['queue'] as List).length, 1);
      expect(service.isPolling, isTrue);
      store.fail = false;
      core.afterStart = null;
    },
  );
  test('bookmarks keep native no-revive/recent options distinct from explicit links', () async {
    await service.enqueueLinks(['https://x.com/s/status/1']);
    await service.importBookmarks('/synthetic/bookmarks.json');
    await service.start();
    expect(core.starts.length, 2);
    expect(core.starts[0].revive, isTrue);
    expect(core.starts[0].mark_recent, isFalse);
    expect(core.starts[1].revive, isFalse);
    expect(core.starts[1].mark_recent, isTrue);
  });
  test('shared id is acknowledged only after durable commit, including restart redelivery', () async {
    final event = ShareLinksReady('share-1', ['https://x.com/s/status/1']);
    var acknowledgments = 0;
    Future<void> ack(String id) async {
      expect((store.saved!['acceptedShares'] as List), contains(id));
      acknowledgments++;
    }

    store.fail = true;
    await expectLater(
      service.acceptSharedLinks(event, acknowledge: ack),
      throwsA(isA<FileSystemException>()),
    );
    expect(acknowledgments, 0);
    store.fail = false;
    await service.acceptSharedLinks(event, acknowledge: ack);
    expect(acknowledgments, 1);
    await service.start();
    expect(service.queue, isEmpty);
    await service.close();
    service = DownloadService(
      core: core,
      store: store,
      pollInterval: const Duration(days: 1),
    );
    await service.initialize();
    await service.acceptSharedLinks(event, acknowledge: ack);
    expect(acknowledgments, 2);
    expect(service.queue, isEmpty);
    expect(core.starts.length, 1);
  });
  test(
    'pause/resume/cancel preserve queue controls and idle stops polling',
    () async {
      await service.enqueueLinks(['https://x.com/s/status/1']);
      await service.start();
      expect(service.phase, DownloadPhase.running);
      await service.pause();
      expect(service.phase, DownloadPhase.paused);
      expect(service.isPolling, isFalse);
      await expectLater(
        service.start(),
        throwsA(isA<DownloadServiceException>()),
      );
      await service.enqueueLinks(['https://x.com/s/status/2']);
      expect(service.queue.length, 1);
      await service.resume();
      expect(core.resumes.length, 1);
      expect(service.queue, isEmpty);
      await service.cancel();
      expect(core.stops, [true, false]);
      expect(service.phase, DownloadPhase.cancelled);
      expect(service.isPolling, isFalse);
    },
  );
  test('starting fresh links leaves older paused core jobs paused', () async {
    await service.enqueueLinks(['https://x.com/s/status/1']);
    await service.start();
    await service.pause();
    await service.enqueueLinks(['https://x.com/s/status/2']);
    await service.start();
    expect(core.resumes, isEmpty);
    expect(core.starts.last.urls, ['https://x.com/s/status/2']);
  });
  test(
    'finished reports emit once per generation, with no paused report',
    () async {
      final reports = <DownloadStatus>[];
      service.onFinished = reports.add;
      core.current = snapshot(outcome: 'paused', paused: 1);
      await service.poll();
      expect(reports, isEmpty);
      core.current = snapshot(outcome: 'partial', done: 1);
      await service.poll();
      await service.poll();
      expect(reports.length, 1);
      expect(reports.single.outcome, 'partial');
      expect(service.isPolling, isFalse);
      core.current = snapshot(outcome: 'succeeded', done: 1, generation: 2);
      await service.poll();
      expect(reports.length, 2);
    },
  );
  test('attached actual inbox stays unacknowledged on persistence failure then retries', () async {
    final root = await Directory.systemTemp.createTemp('d1-share-');
    final links = File('${root.path}/Inbox/share-test/_links.json');
    await links.parent.create(recursive: true);
    await links.writeAsString(jsonEncode(['https://x.com/s/status/1']));
    final inbox = ShareInbox(root: root);
    await service.attachShareInbox(inbox);
    store.fail = true;
    await inbox.start();
    await Future<void>.delayed(Duration.zero);
    await service.flush();
    expect(await File('${root.path}/Links/share-test.json').exists(), isTrue);
    store.fail = false;
    await inbox.drain();
    for (
      var i = 0;
      i < 20 && await File('${root.path}/Links/share-test.json').exists();
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await File('${root.path}/Links/share-test.json').exists(), isFalse);
    expect(service.queue.length, 1);
    await inbox.dispose();
    await root.delete(recursive: true);
  });
  test(
    'atomic file store persists replacement and refuses corrupt data',
    () async {
      final root = await Directory.systemTemp.createTemp('d1-store-');
      final file = File('${root.path}/outbox.json');
      final store = FileDownloadQueueStore(file);
      await store.write({'version': 1});
      await store.write({'version': 2});
      expect((await store.read())!['version'], 2);
      expect((await root.list().toList()).length, 1);
      await file.writeAsString('not-json');
      await expectLater(store.read(), throwsFormatException);
      await root.delete(recursive: true);
    },
  );
}
