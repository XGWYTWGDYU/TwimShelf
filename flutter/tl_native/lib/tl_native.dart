import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native helpers (iOS, iPadOS, macOS, Android). Every call returns null/false where the
/// platform has none, so callers keep their portable fallback.
class TlNative {
  TlNative._();
  static const _channel = MethodChannel('tl/native');

  /// Files dropped on the window (iOS): copies in the app's temporary folder.
  static set onDropped(void Function(List<String>)? f) {
    _channel.setMethodCallHandler(f == null
        ? null
        : (call) async {
            if (call.method == 'dropped') f((call.arguments as List).cast<String>());
          });
  }

  static bool get hasPosters => !kIsWeb && (Platform.isIOS || Platform.isMacOS || Platform.isAndroid);

  /// Square JPEG posters of the video at [at], one per side in [sides], written to [out] with
  /// `{side}` replaced by the side. The frame is decoded once, by the system's decoder.
  static Future<bool> posterFrame(String path, {required List<int> sides, required String out, bool whole = false, Duration at = const Duration(milliseconds: 500)}) async {
    if (!hasPosters) return false;
    try {
      return await _channel.invokeMethod<bool>('posterFrame', {'path': path, 'sides': sides, 'out': out, 'whole': whole, 'atMs': at.inMilliseconds}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Where the app itself is installed (iOS, macOS: the bundle; Android: the APKs); empty where
  /// the platform has no such call (the caller uses the executable's folder).
  static Future<List<String>> appPaths() async {
    if (!hasPosters) return const [];
    try {
      return (await _channel.invokeListMethod<String>('appPaths')) ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// iOS, macOS: the shares folder in the app group, shared with the share extension.
  static Future<String?> sharesRoot() => _channel.invokeMethod<String>('sharesRoot');

  /// Android: the folder an update's APK must be downloaded into (the installer reads it there).
  static Future<String?> updatesDir() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('updatesDir');
    } on PlatformException {
      return null;
    }
  }

  /// Android: hands the APK to the system's installer. False when the app may not install
  /// packages yet (the system's page for allowing it was opened instead).
  static Future<bool> installApk(String path) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
