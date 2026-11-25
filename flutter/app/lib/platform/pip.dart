import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'os.dart';

/// Android Picture-in-Picture bridge (`org.twimshelf/pip`).
abstract final class AndroidPip {
  static const _channel = MethodChannel('org.twimshelf/pip');
  static final inPip = ValueNotifier<bool>(false);
  static bool _initialized = false;
  static bool? _supported;

  static void _ensureInitialized() {
    if (_initialized || !OS.isAndroid) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        inPip.value = call.arguments == true;
      }
    });
  }

  static Future<bool> isSupported() async {
    if (!OS.isAndroid) return false;
    _ensureInitialized();
    if (_supported != null) return _supported!;
    try {
      return _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return _supported = false;
    }
  }

  static Future<bool> enter({int width = 16, int height = 9}) async {
    if (!OS.isAndroid) return false;
    _ensureInitialized();
    try {
      final ok = await _channel.invokeMethod<bool>('enter', {
            'width': width > 0 ? width : 16,
            'height': height > 0 ? height : 9,
          }) ??
          false;
      if (ok) inPip.value = true;
      return ok;
    } catch (_) {
      return false;
    }
  }
}
