import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../platform/secrets.dart' as secrets;
import '../platform/share_inbox.dart';
import '../platform/background_work.dart';
import '../platform/system_random.dart';

abstract interface class DownloadCore {
  Future<int> start(DownloadRequest request);
  Future<int> stop(bool pause);
  Future<int> resume(DownloadRequest request);
  Future<DownloadStatus?> status();
  Future<List<String>> bookmarks(String path);
  Future<void> applyCookies(DownloadRoute route);
}

class NativeDownloadCore implements DownloadCore {
  @override
  Future<int> start(DownloadRequest request) =>
      Core.startDownloadAsync(request);
  @override
  Future<int> stop(bool pause) => Core.stopDownloadAsync(pause);
  @override
  Future<int> resume(DownloadRequest request) =>
      Core.resumeDownloadAsync(request);
  @override
  Future<DownloadStatus?> status() => Core.downloadStatusAsync();
  @override
  Future<List<String>> bookmarks(String path) =>
      Isolate.run(() => Core.bookmarkURLs(path));
  @override
  Future<void> applyCookies(DownloadRoute route) async {
    final result = await secrets.Session.applyStoredCookies();
    if (route == DownloadRoute.cookie &&
        result is secrets.SecretsUnavailable<void>) {
      throw const DownloadServiceException('settings.cookie.keychainRefused');
    }
  }
}

abstract interface class DownloadQueueStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  /// Moves an unreadable file out of the way, keeping it; where it went.
  Future<String?> setAside();
}

/// Atomic, flushed outbox. It contains canonical public URLs/options, NEVER cookies.
class FileDownloadQueueStore implements DownloadQueueStore {
  FileDownloadQueueStore(this.file);
  final File file;
  @override
  Future<Map<String, dynamic>?> read() async {
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<String?> setAside() async {
    if (!await file.exists()) return null;
    final kept = '${file.path}.damaged-${DateTime.now().millisecondsSinceEpoch}';
    await file.rename(kept);
    return kept;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final random = const SystemRandom().nextInt(1 << 32);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$random.partial',
    );
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class DownloadServiceException implements Exception {
  const DownloadServiceException(this.messageKey);
  final String messageKey;
  @override
  String toString() => messageKey;
}

class QueuedDownload {
  const QueuedDownload({
    required this.url,
    this.source,
    this.revive = true,
    this.markRecent = false,
    this.folder,
  });
  final String url;
  final String? source;
  /// Where the share page said this goes; null: the page's folder.
  final String? folder;
  final bool revive, markRecent;
  String get identity => Uri.parse(url).pathSegments.last;
  Map<String, dynamic> toJson() => {
    'url': url,
    'source': source,
    'revive': revive,
    'folder': folder,
    'markRecent': markRecent,
  };
  factory QueuedDownload.fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String;
    final normalized = parseSharedPostLinks(url);
    if (normalized.length != 1 || normalized.single != url) {
      throw const FormatException('downloads.invalidQueue');
    }
    return QueuedDownload(
      url: url,
      source: json['source'] as String?,
      revive: json['revive'] as bool,
      markRecent: json['markRecent'] as bool,
      folder: json['folder'] as String?,
    );
  }
}

enum DownloadPhase {
  idle,
  queued,
  running,
  pausing,
  paused,
  cancelling,
  cancelled,
  failed,
}

/// One service per OPEN library. Queue mutations and core handoffs are serialized.
/// initialize/create does not start network work: the UI explicitly calls start,
/// or resume for paused jobs. Core-owned jobs survive process restarts themselves.
class DownloadService extends ChangeNotifier {
  DownloadService({
    required this.core,
    required this.store,
    this.onFinished,
    this.pollInterval = const Duration(seconds: 1),
    BackgroundWork? backgroundWork,
  }) : _background = backgroundWork ?? platformBackgroundWork() {
    _background.onTimeout = () {
      _backgroundExpired = true;
      _backgroundReady = false;
      if (!_disposed && _initialized) {
        unawaited(pause().catchError((Object _) {}));
      }
    };
  }
  final BackgroundWork _background;
  bool _backgroundReady = false, _backgroundExpired = false;
  Future<void> _ensureBackground() async {
    if (_backgroundExpired) {
      throw const DownloadServiceException('settings.resume');
    }
    if (_backgroundReady) return;
    try {
      await _background.start();
    } catch (_) {
      throw const DownloadServiceException('common.couldNotStartDownload');
    }
    if (_backgroundExpired) {
      throw const DownloadServiceException('settings.resume');
    }
    _backgroundReady = true;
  }

  final DownloadCore core;
  final DownloadQueueStore store;
  final Duration pollInterval;
  void Function(DownloadStatus)? onFinished;
  static Future<DownloadService> create({
    Directory? libraryDirectory,
    void Function(DownloadStatus)? onFinished,
  }) async {
    final root =
        libraryDirectory ??
        Directory(
          Platform.environment['TL_LIBRARY_DIR'] ??
              (await getApplicationSupportDirectory()).path,
        );
    final service = DownloadService(
      core: NativeDownloadCore(),
      store: FileDownloadQueueStore(File('${root.path}/downloads.queue.json')),
      onFinished: onFinished,
    );
    await service.initialize();
    return service;
  }

  List<QueuedDownload> _queue = [];
  Set<String> _acceptedShares = {};
  String _mode = 'active';
  DownloadRoute _route = DownloadRoute.auto;
  int concurrency = 3, intervalMs = 500;
  String? folder;
  DownloadStatus? _status;
  DownloadStatus? get status => _status;
  Object? _lastError;
  Object? get lastError => _lastError;
  String? get errorKey => _lastError == null
      ? null
      : _lastError is DownloadServiceException
      ? (_lastError as DownloadServiceException).messageKey
      : 'common.couldNotStartDownload';
  List<QueuedDownload> get queue => List.unmodifiable(_queue);
  DownloadRoute get route => _route;
  set route(DownloadRoute value) {
    _route = value;
    _notify();
    if (_initialized && !_disposed) {
      unawaited(_serial(() => _commit()).catchError((Object _) {}));
    }
  }

  bool _initialized = false, _disposed = false, _pollQueued = false;
  Timer? _timer;
  bool get isPolling => _timer != null;
  Future<void> _tail = Future.value();
  StreamSubscription<ShareInboxEvent>? _shares;
  final _reported = <int>{};
  DownloadPhase get phase {
    if (_status?.running == true) {
      if (_mode == 'paused') return DownloadPhase.pausing;
      if (_mode == 'cancelled') return DownloadPhase.cancelling;
      return DownloadPhase.running;
    }
    if (_lastError != null) return DownloadPhase.failed;
    if (_mode == 'paused' || (_status?.paused ?? 0) > 0) {
      return DownloadPhase.paused;
    }
    if (_queue.isNotEmpty) return DownloadPhase.queued;
    if (_mode == 'cancelled') return DownloadPhase.cancelled;
    if (_status?.outcome == 'failed') return DownloadPhase.failed;
    return DownloadPhase.idle;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _ready() {
    if (_disposed) throw StateError('downloads.disposed');
    if (!_initialized) throw StateError('downloads.notInitialized');
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _tail.then((_) async {
      if (_disposed) throw StateError('downloads.disposed');
      try {
        _lastError = null;
        await action();
        _notify();
      } catch (error) {
        _lastError = error;
        _notify();
        rethrow;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> initialize() => _serial(() async {
    if (_initialized) return;
    Map<String, dynamic>? saved;
    try {
      saved = await store.read();
      if (saved != null && saved['version'] != 1) throw const FormatException('downloads.invalidQueue');
      for (final v in (saved?['queue'] as List?) ?? const []) {
        QueuedDownload.fromJson(v as Map<String, dynamic>);
      }
    } catch (e) {
      // a damaged file must not keep the library from opening: it is kept, and the page says so
      damagedQueue = await store.setAside();
      _lastError = e;
      saved = null;
    }
    final data = saved;
    try {
    if (data != null) {
      if (data['version'] != 1) {
        throw const FormatException('downloads.invalidQueue');
      }
      final queue = (data['queue'] as List)
          .map((v) => QueuedDownload.fromJson(v as Map<String, dynamic>))
          .toList();
      if (queue.map((e) => e.identity).toSet().length != queue.length) {
        throw const FormatException('downloads.duplicateQueue');
      }
      final mode = data['mode'] as String;
      if (!['active', 'paused', 'cancelled'].contains(mode)) {
        throw const FormatException('downloads.invalidQueue');
      }
      _queue = queue;
      _mode = mode;
      _route = DownloadRoute.values.firstWhere(
        (r) => r.wireValue == data['route'],
      );
      concurrency = (data['concurrency'] as int? ?? 3).clamp(1, 16);
      intervalMs = (data['intervalMs'] as int? ?? 500).clamp(0, 600000);
      folder = data['folder'] as String?;
      _acceptedShares = (data['acceptedShares'] as List)
          .cast<String>()
          .toSet();
    }
    } catch (e) {
      // the rest of it is as unreadable: same as above
      damagedQueue = await store.setAside();
      _lastError = e;
      _queue = [];
      _acceptedShares = {};
    }
    _initialized = true;
    await _refresh();
  });
  Future<void> _commit({
    List<QueuedDownload>? queue,
    Set<String>? shares,
    String? mode,
  }) async {
    final nextQueue = queue ?? _queue,
        nextShares = shares ?? _acceptedShares,
        nextMode = mode ?? _mode;
    await store.write({
      'version': 1,
      'route': _route.wireValue,
      'mode': nextMode,
      'concurrency': concurrency.clamp(1, 16),
      'intervalMs': intervalMs.clamp(0, 600000),
      'folder': folder,
      'queue': nextQueue.map((e) => e.toJson()).toList(),
      'acceptedShares': nextShares.toList(),
    });
    _queue = nextQueue;
    _acceptedShares = nextShares;
    _mode = nextMode;
    _notify();
  }

  List<QueuedDownload> _adding(
    List<String> values, {
    String? source,
    bool revive = true,
    bool recent = false,
    String? folder,
  }) {
    final entries = <String, QueuedDownload>{
      for (final e in _queue) e.identity: e,
    };
    for (final value in values) {
      final urls = parseSharedPostLinks(value);
      if (urls.isEmpty) {
        throw const DownloadServiceException('settings.links.unrecognized');
      }
      for (final url in urls) {
        final entry = QueuedDownload(
          url: url,
          source: source,
          revive: revive,
          markRecent: recent,
          folder: folder,
        );
        final previous = entries[entry.identity];
        entries[entry.identity] = previous == null
            ? entry
            : QueuedDownload(
                url: previous.url,
                source: previous.source ?? source,
                revive: previous.revive || revive,
                markRecent: previous.markRecent || recent,
                folder: previous.folder ?? folder,
              );
      }
    }
    return entries.values.toList();
  }

  Future<void> enqueueLinks(List<String> links, {String? source}) =>
      _serial(() async {
        _ready();
        await _commit(
          queue: _adding(links, source: source),
          mode: _mode == 'cancelled' ? 'active' : null,
        );
        if (_status?.running == true && _mode == 'active') await _handoff();
      });
  /// Links pasted by hand: queued, then the download goes.
  Future<void> startLinks(List<String> links) async {
    await enqueueLinks(links);
    await start();
  }

  Future<void> importBookmarks(String path) => _serial(() async {
    _ready();
    final urls = await core.bookmarks(path);
    await _commit(
      queue: _adding(urls, source: path, revive: false, recent: true),
      mode: _mode == 'cancelled' ? 'active' : null,
    );
    if (_status?.running == true && _mode == 'active') await _handoff();
  });
  DownloadRequest _request(List<QueuedDownload> batch) => DownloadRequest(
    urls: batch.map((e) => e.url).toList(),
    route: _route,
    concurrency: concurrency.clamp(1, 16),
    interval_ms: intervalMs.clamp(0, 600000),
    folder: batch.isNotEmpty ? batch.first.folder ?? folder : folder,
    revive: batch.isEmpty ? false : batch.first.revive,
    mark_recent: batch.isNotEmpty && batch.first.markRecent,
  );
  Future<void> _handoff() async {
    while (_queue.isNotEmpty) {
      final first = _queue.first;
      final batch = _queue
          .takeWhile(
            (e) => e.revive == first.revive && e.markRecent == first.markRecent && e.folder == first.folder,
          )
          .toList();
      await _ensureBackground();
      await core.start(
        _request(batch),
      ); // Return means all URLs were committed by core.
      try {
        await _commit(queue: _queue.skip(batch.length).toList());
      } finally {
        await _refresh();
      }
    }
  }

  Future<void> start() => _serial(() async {
    _ready();
    if (_queue.isEmpty && (_mode == 'paused' || (_status?.paused ?? 0) > 0)) {
      throw const DownloadServiceException('settings.resume');
    }
    await core.applyCookies(_route);
    _backgroundExpired = false;
    await _ensureBackground();
    try {
      await _commit(mode: 'active');
      if (_queue.isEmpty) {
        await core.start(_request([]));
      } else {
        await _handoff();
      }
    } finally {
      await _refresh();
    }
  });
  Future<void> pause() => _serial(() async {
    _ready();
    await _commit(mode: 'paused');
    await core.stop(true);
    await _refresh();
  });
  Future<void> resume() => _serial(() async {
    _ready();
    await core.applyCookies(_route);
    _backgroundExpired = false;
    await _ensureBackground();
    try {
      await _commit(mode: 'active');
      await core.resume(_request([]));
      await _refresh();
      await _handoff();
    } finally {
      await _refresh();
    }
  });
  /// The data folder is about to move: what runs stops, and goes on from the new place.
  Future<void> pauseForMove() => _serial(() async {
    _ready();
    await core.stop(true);
    await _refresh();
  });

  /// 清除所有数据: nothing left to send, the record of accepted shares gone, the file too.
  Future<void> discardAll() => _serial(() async {
    _ready();
    await _commit(queue: [], shares: {}, mode: 'active');
    await core.stop(false);
    await _refresh();
  });

  /// Saved settings or links this version cannot read: kept aside under this name, not deleted.
  String? damagedQueue;

  Future<void> cancel() => _serial(() async {
    _ready();
    // Explicit cancellation intentionally discards unsent links. Persist that
    // intent before the stop, so a crash cannot start them on the next launch.
    await _commit(queue: [], mode: 'cancelled');
    await core.stop(false);
    await _refresh();
  });
  Future<void> poll() => _serial(() async {
    _ready();
    await _refresh();
  });
  Future<void> _refresh() async {
    _status = await core.status();
    if (_status?.running == true) {
      _timer ??= Timer.periodic(pollInterval, (_) {
        if (_pollQueued || _disposed) return;
        _pollQueued = true;
        unawaited(
          poll()
              .catchError((Object _) {})
              .whenComplete(() => _pollQueued = false),
        );
      });
      if (!_backgroundExpired) {
        await _ensureBackground();
        await _background.update(_status!);
      }
    } else {
      _timer?.cancel();
      _timer = null;
      if (_backgroundReady) {
        await _background.stop();
        _backgroundReady = false;
      }
    }
    final current = _status;
    if (current != null &&
        !current.running &&
        current.total > 0 &&
        current.generation > 0 &&
        [
          'succeeded',
          'partial',
          'failed',
          'cancelled',
        ].contains(current.outcome) &&
        _reported.add(current.generation)) {
      onFinished?.call(current);
    }
    _notify();
  }

  Future<void> acceptSharedLinks(
    ShareLinksReady event, {
    required Future<void> Function(String) acknowledge,
  }) async {
    await _serial(() async {
      _ready();
      if (!_acceptedShares.contains(event.id)) {
        final queue = _adding(event.links, source: 'share:${event.id}', folder: event.folder);
        await _commit(
          queue: queue,
          shares: {..._acceptedShares, event.id},
          mode: _mode == 'cancelled' ? 'active' : null,
        );
      }
    });
    await acknowledge(event.id); // Only AFTER the durable outbox transaction.
  }

  Future<void> attachShareInbox(ShareInbox inbox) async {
    _ready();
    await _shares?.cancel();
    _shares = inbox.events.listen((event) {
      if (event is ShareLinksReady) {
        unawaited(
          acceptSharedLinks(
            event,
            acknowledge: inbox.acknowledgeLinks,
          ).catchError((Object error) {
            _lastError = error;
            _notify();
          }),
        );
      }
    });
  }

  Future<void> flush() async {
    await _tail;
  }

  Future<void> close() async {
    await _tail;
    await _background.stop();
    _backgroundReady = false;
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _background.onTimeout = null;
    _background.dispose();
    _timer?.cancel();
    _timer = null;
    unawaited(_shares?.cancel());
    super.dispose();
  }
}
