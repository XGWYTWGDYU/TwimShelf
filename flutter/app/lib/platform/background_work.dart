import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';

abstract interface class BackgroundWork {
  void Function()? get onTimeout;
  set onTimeout(void Function()? callback);
  Future<void> start();
  Future<void> update(DownloadStatus status);
  Future<void> stop();
  void dispose();
}

class NoBackgroundWork implements BackgroundWork {
  @override
  void Function()? onTimeout;
  @override
  Future<void> start() async {}
  @override
  Future<void> update(DownloadStatus status) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

BackgroundWork platformBackgroundWork() =>
    Platform.isAndroid ? AndroidBackgroundWork() : NoBackgroundWork();

class BackgroundWorkUnavailable implements Exception {
  const BackgroundWorkUnavailable();
}

/// Texts are resolved from the initialized catalog, never duplicated in Kotlin.
class AndroidBackgroundWork implements BackgroundWork {
  AndroidBackgroundWork({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('org.twimshelf/android_platform') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'backgroundTimeout') {
        _active = false;
        onTimeout?.call();
      }
    });
  }
  final MethodChannel _channel;
  bool _active = false, _disposed = false;
  @override
  void Function()? onTimeout;
  Map<String, Object> _text({DownloadStatus? status}) => {
    'title': L('activity.downloadingPosts'),
    'channelName': L('activity.downloadingPosts'),
    'body': status == null
        ? L('activity.running')
        : L('activity.downloadSummary', [
            status.done,
            status.skipped,
            status.failed,
            status.total,
          ]),
    'total': status?.total ?? 0,
    'done': status == null ? 0 : status.done + status.skipped + status.failed,
  };
  @override
  Future<void> start() async {
    if (_disposed) throw const BackgroundWorkUnavailable();
    if (_active) return;
    try {
      // Permission is requested while the user starts work in the foreground.
      // Denial hides drawer notifications on13+, but does not prohibit an FGS.
      await _channel.invokeMethod<bool>('notificationPermission');
      await _channel
          .invokeMethod<void>('backgroundStart', _text())
          .timeout(const Duration(seconds: 10));
      _active = true;
    } catch (_) {
      throw const BackgroundWorkUnavailable();
    }
  }

  @override
  Future<void> update(DownloadStatus status) async {
    if (!_active || _disposed) return;
    try {
      await _channel.invokeMethod<void>(
        'backgroundUpdate',
        _text(status: status),
      );
    } catch (_) {
      throw const BackgroundWorkUnavailable();
    }
  }

  @override
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await _channel
          .invokeMethod<void>('backgroundStop')
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onTimeout = null;
    unawaited(stop());
    _channel.setMethodCallHandler(null);
  }
}
