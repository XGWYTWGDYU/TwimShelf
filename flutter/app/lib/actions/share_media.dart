import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../platform/apple_platform.dart';
import '../platform/os.dart';
import '../platform/files.dart';

const _channel = MethodChannel('org.twimshelf/share_inbox');

/// The share button of the viewers. iOS and the Mac: the system's sheet, which holds both copying
/// and the other apps. Android: its sheet has no copying, so 拷贝 stands beside it. Windows and
/// Linux have no such sheet: 拷贝 and 复制到.
Future<void> shareMedia(BuildContext context, String path, {Rect? anchor}) async {
  if (await ApplePlatform.instance.share([path])) return;
  if (!context.mounted) return;
  final copy = _Choice(const ValueKey('shareCopy'), Icons.copy, L('viewer.copy'), () => _copy(context, path));
  final choices = OS.isAndroid
      ? [copy, _Choice(const ValueKey('shareOthers'), Icons.ios_share, L('viewer.shareTo'), () => _others(path, anchor))]
      : [copy, _Choice(const ValueKey('shareCopyTo'), Icons.drive_file_move_outlined, L('viewer.copyTo'), () => _copyTo(context, path))];
  final chosen = await (OS.isAndroid
      ? showModalBottomSheet<_Choice>(
          context: context,
          builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [for (final o in choices) ListTile(key: o.key, leading: Icon(o.icon), title: Text(o.title), onTap: () => Navigator.pop(c, o))])),
        )
      : _menu(context, choices, anchor));
  chosen?.run();
}

Future<_Choice?> _menu(BuildContext context, List<_Choice> choices, Rect? anchor) {
  final screen = MediaQuery.sizeOf(context);
  final at = anchor ?? Rect.fromCenter(center: screen.center(Offset.zero), width: 1, height: 1);
  return showMenu<_Choice>(
    context: context,
    position: RelativeRect.fromLTRB(at.left, at.top - 112, screen.width - at.right, screen.height - at.top),
    items: [for (final o in choices) PopupMenuItem(key: o.key, value: o, child: Row(children: [Icon(o.icon, size: 20), const SizedBox(width: 12), Text(o.title)]))],
  );
}

class _Choice {
  const _Choice(this.key, this.icon, this.title, this.run);
  final Key key;
  final IconData icon;
  final String title;
  final VoidCallback run;
}

void _toast(BuildContext context, String text) {
  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
}

Future<void> _copy(BuildContext context, String path) async {
  try {
    await _channel.invokeMethod<void>('copyFile', path);
    if (context.mounted && !OS.isAndroid) _toast(context, L('viewer.copied'));
  } catch (_) {
    if (context.mounted) _toast(context, L('viewer.copyFailed'));
  }
}

Future<void> _others(String path, Rect? anchor) async {
  if (OS.isWeb) return downloadToBrowser(path);
  try {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], sharePositionOrigin: anchor));
  } catch (_) {}
}

Future<void> _copyTo(BuildContext context, String path) async {
  if (OS.isWeb) return downloadToBrowser(path);
  final place = await getSaveLocation(suggestedName: path.split(RegExp(r'[/\\\\]')).last);
  if (place == null) return;
  try {
    await File(path).copy(place.path);
    if (context.mounted) _toast(context, L('viewer.copiedTo', [place.path]));
  } catch (_) {
    if (context.mounted) _toast(context, L('viewer.copyFailed'));
  }
}
