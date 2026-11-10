
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'apple_platform.dart';
import 'os.dart';

/// Desktop windows without the system's title bar: the app's own content reaches the top edge.
/// macOS keeps its traffic lights over the content (the window's corner); Windows and Linux get
/// the caption buttons drawn here. A drag on the top strip moves the window.
class DesktopWindow {
  static bool get isDesktop => !kIsWeb && (OS.isMacOS || OS.isWindows || OS.isLinux);
  static bool get drawsCaption => !kIsWeb && (OS.isWindows || OS.isLinux);

  /// The height of the strip that stands in for the title bar.
  static double get stripHeight => !isDesktop ? 0 : (OS.isMacOS ? 28 : 36);

  static Future<void> setUp() async {
    if (!isDesktop) return;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: OS.isMacOS);
    } catch (_) {}
  }

  static void startDragging() {
    if (isDesktop) windowManager.startDragging();
  }
}

/// Where the window's own controls sit, so pages keep clear of them: the leading box (macOS's
/// traffic lights, a windowed iPad's controls) and the trailing one (the caption buttons on
/// Windows and Linux). Both empty where there are none.
class WindowChrome {
  static Rect leading(BuildContext context) {
    if (!kIsWeb && OS.isMacOS) return const Rect.fromLTWH(0, 0, 76, 28);
    return ApplePlatform.instance.windowControls.value;
  }

  static Rect trailing(BuildContext context) =>
      DesktopWindow.drawsCaption ? Rect.fromLTWH(MediaQuery.sizeOf(context).width - 138, 0, 138, DesktopWindow.stripHeight) : Rect.zero;

  /// The height everything that touches the top edge leaves free.
  static double top(BuildContext context) {
    final l = leading(context), t = trailing(context);
    return [l.bottom, t.bottom, if (DesktopWindow.isDesktop) DesktopWindow.stripHeight].reduce((a, b) => a > b ? a : b);
  }
}

/// The top strip of a desktop window: drags move the window (a double click zooms it, as the
/// title bar did), and on Windows and Linux the caption buttons sit at its end. Taps on what is
/// under the strip still reach it (it only takes drags).
class WindowStrip extends StatelessWidget {
  const WindowStrip({super.key});

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.isDesktop) return const SizedBox.shrink();
    final h = DesktopWindow.stripHeight;
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      height: h,
      child: Row(children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => DesktopWindow.startDragging(),
            onDoubleTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
        ),
        if (DesktopWindow.drawsCaption) ...[
          WindowCaptionButton.minimize(brightness: brightness, onPressed: () => windowManager.minimize()),
          FutureBuilder<bool>(
            future: windowManager.isMaximized(),
            builder: (context, max) => max.data == true
                ? WindowCaptionButton.unmaximize(brightness: brightness, onPressed: () => windowManager.unmaximize())
                : WindowCaptionButton.maximize(brightness: brightness, onPressed: () => windowManager.maximize()),
          ),
          WindowCaptionButton.close(brightness: brightness, onPressed: () => windowManager.close()),
        ],
      ]),
    );
  }
}
