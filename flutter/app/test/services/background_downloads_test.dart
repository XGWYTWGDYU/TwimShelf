import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/platform/background_work.dart';
import 'package:twimshelf/services/downloads.dart';

import 'downloads_test.dart' show FakeCore, MemoryStore, snapshot;

class RecordingWork implements BackgroundWork {
  @override
  void Function()? onTimeout;
  final events = <String>[];
  bool reject = false, active = false;
  @override
  Future<void> start() async {
    events.add('start');
    if (reject) throw const BackgroundWorkUnavailable();
    active = true;
  }

  @override
  Future<void> update(DownloadStatus status) async {
    events.add('update:${status.done}');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    active = false;
  }

  void expire() {
    active = false;
    onTimeout?.call();
  }

  @override
  void dispose() {
    active = false;
    events.add('dispose');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'foreground ownership precedes core handoff and ends on completion',
    () async {
      final core = FakeCore(), store = MemoryStore(), work = RecordingWork();
      core.afterStart = () => expect(work.active, true);
      final service = DownloadService(
        core: core,
        store: store,
        backgroundWork: work,
      );
      await service.initialize();
      await service.enqueueLinks(['https://x.com/seed/status/1']);
      await service.start();
      expect(work.events.first, 'start');
      expect(service.queue, isEmpty);
      core.current = snapshot(outcome: 'succeeded', total: 1, done: 1);
      await service.poll();
      expect(work.events.last, 'stop');
      expect(work.active, false);
      await service.close();
    },
  );
  test('foreground rejection and core failure keep the outbox and release ownership', () async {
    final core = FakeCore(),
        store = MemoryStore(),
        work = RecordingWork()..reject = true;
    final service = DownloadService(
      core: core,
      store: store,
      backgroundWork: work,
    );
    await service.initialize();
    await service.enqueueLinks(['https://x.com/seed/status/1']);
    await expectLater(
      service.start(),
      throwsA(isA<DownloadServiceException>()),
    );
    expect(core.starts, isEmpty);
    expect(service.queue, hasLength(1));
    work.reject = false;
    core.failStart = true;
    await expectLater(service.start(), throwsStateError);
    expect(service.queue, hasLength(1));
    expect(work.active, false);
    await service.close();
  });
  test('Android quota timeout durably pauses native jobs and explicit resume reacquires', () async {
    final core = FakeCore(), store = MemoryStore(), work = RecordingWork();
    final service = DownloadService(
      core: core,
      store: store,
      backgroundWork: work,
    );
    await service.initialize();
    await service.enqueueLinks(['https://x.com/seed/status/1']);
    await service.start();
    work.expire();
    await service.flush();
    expect(core.stops, [true]);
    expect(store.saved!['mode'], 'paused');
    expect(work.active, false);
    await service.resume();
    expect(work.events.where((e) => e == 'start'), hasLength(2));
    expect(work.active, true);
    await service.cancel();
    expect(work.active, false);
    await service.close();
  });
}
