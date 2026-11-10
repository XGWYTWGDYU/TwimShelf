
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';

import '../l10n/l10n.dart';
import 'os.dart';

/// 下载帖子 on the app's icon: pressing it long on iOS and Android, the Dock's menu on the Mac, the
/// taskbar's on Windows, the launcher's on Linux. It opens 浏览 with the quick download card.
/// Windows and Linux hand the request over as an inbox request (`--quick-download`; `ShareInbox`), as
/// a second start of the program must.
class QuickAction {
  QuickAction._();
  static const _download = 'downloadPosts';
  static const _dock = MethodChannel('org.twimshelf/quick_action');

  /// Moves when it is asked for.
  static final requests = ValueNotifier<int>(0);
  static bool _pending = false;

  static void request() {
    _pending = true;
    requests.value++;
  }

  /// True once per request: whoever opens the card.
  static bool take() {
    final p = _pending;
    _pending = false;
    return p;
  }

  static Future<void> start() async {
    if (OS.isIOS || OS.isAndroid) {
      const actions = QuickActions();
      await actions.initialize((type) {
        if (type == _download) request();
      });
      await actions.setShortcutItems([ShortcutItem(type: _download, localizedTitle: L('shortcut.downloadPosts'), icon: 'ic_shortcut_download')]);
    } else if (OS.isMacOS) {
      _dock.setMethodCallHandler((call) async {
        if (call.method == _download) request();
      });
      await _dock.invokeMethod<void>('setTitle', L('shortcut.downloadPosts'));
    }
  }
}
