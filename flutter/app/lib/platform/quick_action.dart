
import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

import '../l10n/l10n.dart';
import 'os.dart';

/// 下载帖子 on the app's icon (pressed long, on iOS and Android): it opens 浏览 with the quick
/// download card.
class QuickAction {
  QuickAction._();
  static const _download = 'downloadPosts';

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
    }
  }
}
