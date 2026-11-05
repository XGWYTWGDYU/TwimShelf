import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Ref-counts logical sync owners; Android keeps a single non-reference-counted
/// system lock. Calls are serialized even when start/dispose overlap.
class MulticastController {
  MulticastController({MethodChannel? channel, bool? android})
    : _channel =
          channel ??
          const MethodChannel('org.twimshelf/android_platform'),
      _android = android ?? Platform.isAndroid;
  final MethodChannel _channel;
  final bool _android;
  int _owners = 0;
  Future<void> _tail = Future.value();
  String? lastErrorKey;
  Future<void> _serial(Future<void> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> acquire() => _serial(() async {
    if (!_android) return;
    if (_owners > 0) {
      _owners++;
      return;
    }
    try {
      await _channel.invokeMethod<void>('multicastAcquire');
      _owners = 1;
      lastErrorKey = null;
    } catch (_) {
      lastErrorKey = 'sync.err.paused';
    }
  });
  Future<void> release() => _serial(() async {
    if (!_android || _owners == 0) return;
    if (--_owners > 0) return;
    try {
      await _channel.invokeMethod<void>('multicastRelease');
    } catch (_) {}
  });
}

class Multicast {
  static final _controller = MulticastController();
  static String? get lastErrorKey => _controller.lastErrorKey;
  static Future<void> acquire() => _controller.acquire();
  static Future<void> release() => _controller.release();
}
