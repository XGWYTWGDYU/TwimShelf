
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'os.dart';

/// Small things only the Apple runners know: the device's name as the native apps show it, and
/// on iPad the box the window controls (close / minimise / full screen) take in a windowed scene.
class ApplePlatform with WidgetsBindingObserver {
  ApplePlatform._();
  static final instance = ApplePlatform._();
  static const _channel = MethodChannel('tl/native');

  /// The window controls' box on a windowed iPad (from the window's top-leading corner); empty
  /// everywhere else, so nothing makes room for it on other platforms.
  final windowControls = ValueNotifier<Rect>(Rect.zero);
  bool _watching = false;

  static bool get isApple => !kIsWeb && (OS.isIOS || OS.isMacOS);

  Future<String?> deviceName() async {
    if (!isApple) return null;
    try {
      return await _channel.invokeMethod<String>('deviceName');
    } catch (_) {
      return null;
    }
  }

  /// iphone or ipad (the runner knows the idiom); null elsewhere.
  Future<String?> deviceKind() async {
    if (kIsWeb || !OS.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('deviceKind');
    } catch (_) {
      return null;
    }
  }

  /// The system share sheet (iOS): centred, no arrow, on iPad. False where the runner cannot.
  Future<bool> share(List<String> paths) async {
    if (kIsWeb || !OS.isIOS) return false;
    try {
      await _channel.invokeMethod<void>('share', paths);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts following the window (resizing, entering or leaving full screen) on iOS.
  void watch() {
    if (_watching || kIsWeb || !OS.isIOS) return;
    _watching = true;
    WidgetsBinding.instance.addObserver(this);
    _update();
  }

  @override
  void didChangeMetrics() => _update();

  Future<void> _update() async {
    try {
      final m = await _channel.invokeMapMethod<String, double>('windowControls');
      if (m == null) return;
      final r = Rect.fromLTWH(m['leading'] ?? 0, m['top'] ?? 0, m['width'] ?? 0, m['height'] ?? 0);
      windowControls.value = r.width > 0 && r.height > 0 ? r : Rect.zero;
    } catch (_) {}
  }
}
