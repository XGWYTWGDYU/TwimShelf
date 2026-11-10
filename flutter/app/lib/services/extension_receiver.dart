import 'package:flutter/foundation.dart';
import 'package:tl_core/tl_core.dart';

import '../app/sync_model.dart';
import '../platform/os.dart';
import 'downloads.dart';

/// The browser extension's receiver on this device (the core answers it, see the core's
/// `extension.rs`): the desktop apps listen while open; the web build's server listens on its own
/// at all times (it keeps its download settings in sync from the queue file).
class ExtensionReceiver {
  ExtensionReceiver._();
  static final instance = ExtensionReceiver._();

  /// Where it exists: Windows, Linux and macOS, and the server (the web build). Phones and
  /// tablets do not keep an app running to receive.
  static bool get offered => OS.isWeb || OS.isMacOS || OS.isWindows || OS.isLinux;

  int? port;
  String? problem;
  DownloadService? _downloads;

  /// Starts listening (the desktop apps), and follows the user's download settings so a link from
  /// the browser downloads as one pasted here would.
  void start(DownloadService downloads) {
    if (!offered || OS.isWeb) return;
    _downloads = downloads;
    downloads.addListener(_apply);
    _apply();
  }

  void _apply() {
    final d = _downloads;
    if (d == null) return;
    try {
      port = Core.extensionServe({
        'name': SyncModel.deviceName,
        'platform': OS.isMacOS ? 'macos' : OS.isWindows ? 'windows' : 'linux',
        'flavor': 'flutter',
        'route': d.route.wireValue,
        'concurrency': d.concurrency,
        'interval_ms': d.intervalMs,
        'folder': d.folder,
        'listen': true,
      });
      problem = null;
    } catch (e) {
      problem = '$e';
      debugPrint('extension receiver: $e');
    }
  }
}
