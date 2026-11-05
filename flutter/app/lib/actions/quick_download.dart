import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/library.dart';
import '../l10n/l10n.dart';
import '../platform/shared_links.dart';
import '../screens/settings/downloads_page.dart';
import '../services/downloads.dart';
import '../widgets/text_menu.dart';

/// The links typed so far; they stay when the card closes without downloading, as native.
String _draft = '';

/// The quick download button: a small card under the button for links, as the native apps. The
/// download page's method and folder apply; 跳转到下载设置 carries the links over to that page.
/// [button] is the button's own context, which places the card; [at] places it instead where there
/// is no button to hang it from.
Future<void> showQuickDownload(BuildContext button, {required DownloadService downloads, LibraryModel? library, Rect? at}) {
  final navigator = Navigator.of(button);
  final box = at == null ? button.findRenderObject() as RenderBox? : null;
  var anchor = at ?? Rect.zero;
  return showGeneralDialog<void>(
    context: button,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(button).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) {
      final media = MediaQuery.of(context);
      // where the button is now: the window may have changed size or turned since it opened
      if (box != null && box.attached) anchor = box.localToGlobal(Offset.zero) & box.size;
      final place = quickDownloadPlace(anchor, media.size);
      return Stack(children: [
        Positioned(
          top: place.top,
          left: place.left,
          width: place.width,
          child: ConstrainedBox(
            // above the keyboard, scrolling when there is too little room
            constraints: BoxConstraints(maxHeight: math.max(120.0, media.size.height - media.viewInsets.bottom - place.top - 12)),
            child: QuickDownloadCard(
              downloads: downloads,
              openSettings: () {
                final links = _draft;
                _draft = '';
                Navigator.of(context).pop();
                navigator.push(MaterialPageRoute(builder: (_) => DownloadsPage(downloads: downloads, library: library, initialLinks: links)));
              },
            ),
          ),
        ),
      ]);
    },
  );
}

/// Under the button, its right edge at the button's, and always wholly on the screen: on a phone the
/// card is about as wide as the screen, whichever button of the row it hangs from.
({double left, double top, double width}) quickDownloadPlace(Rect button, Size screen) {
  const margin = 12.0;
  final width = math.min(380.0, screen.width - 2 * margin);
  return (left: (button.right - width).clamp(margin, screen.width - margin - width), top: button.bottom + 6, width: width);
}

class QuickDownloadCard extends StatefulWidget {
  const QuickDownloadCard({super.key, required this.downloads, required this.openSettings});
  final DownloadService downloads;
  final VoidCallback openSettings;

  @override
  State<QuickDownloadCard> createState() => _QuickDownloadCardState();
}

class _QuickDownloadCardState extends State<QuickDownloadCard> {
  late final _links = TextEditingController(text: _draft);
  String? _error;
  bool _starting = false;

  bool get _empty => _links.text.trim().isEmpty;

  /// A double click in the field brings in the post links on the clipboard, without a word
  /// about it. The system may refuse each time; it is asked again the next time.
  Duration? _lastPress;
  void _pressed(PointerDownEvent e) {
    final last = _lastPress;
    _lastPress = e.timeStamp;
    if (last != null && e.timeStamp - last < kDoubleTapTimeout) {
      _lastPress = null;
      unawaited(_pasteLinks());
    }
  }

  Future<void> _pasteLinks() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {}
    if (text == null || !mounted) return;
    final have = _links.text.split(RegExp(r'\s+')).where((l) => l.isNotEmpty).toList();
    final fresh = parseSharedPostLinks(text).where((l) => !have.contains(l)).toList();
    if (fresh.isEmpty) return;
    final all = [...have, ...fresh].join('\n');
    setState(() {
      _links.value = TextEditingValue(text: all, selection: TextSelection.collapsed(offset: all.length));
      _draft = all;
      _error = null;
    });
  }

  @override
  void dispose() {
    _links.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_empty || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    String? error;
    try {
      await widget.downloads.startLinks(_links.text.split(RegExp(r'\s+')).where((l) => l.isNotEmpty).toList());
      _draft = '';
    } on DownloadServiceException catch (e) {
      error = L(e.messageKey);
    } catch (_) {
      error = L('common.couldNotStartDownload');
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _starting = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: CallbackShortcuts(
          bindings: {SingleActivator(LogicalKeyboardKey.enter, meta: Platform.isMacOS, control: !Platform.isMacOS): _download},
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(L('common.downloadPosts'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(L('mac.quick.footer'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Listener(onPointerDown: _pressed, child: TextField(contextMenuBuilder: appTextMenu, 
              key: const ValueKey('quickDownloadLinks'),
              controller: _links,
              autofocus: desktop,
              minLines: 6,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(hintText: L('mac.quick.placeholder'), errorText: _error, errorMaxLines: 3, border: const OutlineInputBorder()),
              onChanged: (text) => setState(() {
                _draft = text;
                _error = null;
              }),
            )),
            const SizedBox(height: 16),
            Row(children: [
              Flexible(child: TextButton(key: const ValueKey('quickDownloadSettings'), onPressed: widget.openSettings, child: Text(L('mac.quick.settings')))),
              const Spacer(),
              FilledButton(key: const ValueKey('quickDownloadStart'), onPressed: _empty || _starting ? null : _download, child: Text(L('common.download'))),
            ]),
          ]),
        ),
      ),
    );
  }
}
