import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/background_work.dart';
import 'package:twimshelf/platform/multicast.dart';

DownloadStatus status({
  bool running = true,
  int total = 10,
  int done = 3,
  int skipped = 2,
  int failed = 1,
}) => DownloadStatus(
  outcome: running ? 'running' : 'paused',
  running: running,
  paused: 0,
  total: total,
  done: done,
  skipped: skipped,
  failed: failed,
  active: const [],
  errors: const [],
  generation: 1,
  recent: const [],
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android-background');
  final calls = <MethodCall>[];
  setUp(() async {
    await L10n.load();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'notificationPermission' ? false : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('multicast owners serialize and release exactly once', () async {
    final lock = MulticastController(channel: channel, android: true);
    await Future.wait([lock.acquire(), lock.acquire()]);
    expect(calls.map((c) => c.method), ['multicastAcquire']);
    await lock.release();
    expect(calls, hasLength(1));
    await lock.release();
    await lock.release();
    expect(calls.map((c) => c.method), [
      'multicastAcquire',
      'multicastRelease',
    ]);
    final noop = MulticastController(channel: channel, android: false);
    await noop.acquire();
    await noop.release();
    expect(calls, hasLength(2));
  });
  test('multicast failure is keyed and a later acquisition retries', () async {
    final lock = MulticastController(channel: channel, android: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'rejected'),
        );
    await lock.acquire();
    expect(lock.lastErrorKey, 'sync.err.paused');
    await lock.release();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    await lock.acquire();
    expect(lock.lastErrorKey, isNull);
    await lock.release();
    expect(calls, hasLength(2));
  });
  test(
    'notification denial still permits FGS and all texts are catalog-derived',
    () async {
      final work = AndroidBackgroundWork(channel: channel);
      await work.start();
      await work.start();
      expect(calls.map((c) => c.method), [
        'notificationPermission',
        'backgroundStart',
      ]);
      final args = calls.last.arguments as Map;
      expect(args['title'], L('activity.downloadingPosts'));
      expect(args['body'], L('activity.running'));
      await work.update(status());
      final update = calls.last.arguments as Map;
      expect(update['done'], 6);
      expect(update['total'], 10);
      expect(update['body'], L('activity.downloadSummary', [3, 2, 1, 10]));
      await work.stop();
      await work.stop();
      expect(calls.where((c) => c.method == 'backgroundStop'), hasLength(1));
      work.dispose();
    },
  );
  test(
    'native timeout notifies owner and permits only a fresh foreground start',
    () async {
      final work = AndroidBackgroundWork(channel: channel);
      var expired = 0;
      work.onTimeout = () => expired++;
      await work.start();
      final message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('backgroundTimeout'),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channel.name, message, (_) {});
      expect(expired, 1);
      await work.update(
        status(running: false, total: 1, done: 0, skipped: 0, failed: 0),
      );
      expect(calls.where((c) => c.method == 'backgroundUpdate'), isEmpty);
      await work.start();
      expect(calls.where((c) => c.method == 'backgroundStart'), hasLength(2));
      await work.stop();
      work.dispose();
    },
  );
  test('start rejection is typed; desktop backend does nothing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'rejected'),
        );
    final work = AndroidBackgroundWork(channel: channel);
    await expectLater(work.start(), throwsA(isA<BackgroundWorkUnavailable>()));
    work.dispose();
    final noop = NoBackgroundWork();
    await noop.start();
    await noop.stop();
    noop.dispose();
  });
}
