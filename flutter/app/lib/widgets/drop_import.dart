import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:tl_native/tl_native.dart';

import '../l10n/l10n.dart';
import '../platform/share_inbox.dart';

/// Media dragged onto the window, from another app or the file manager: the share page offers
/// them (`ShareInbox.importDropped`). iOS has no plugin for it: its own runner hands them over
/// through tl_native.
class DropImport extends StatefulWidget {
  const DropImport({super.key, required this.shares, required this.child});
  final ShareInbox shares;
  final Widget child;

  @override
  State<DropImport> createState() => _DropImportState();
}

class _DropImportState extends State<DropImport> {
  bool _over = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) TlNative.onDropped = _dropped;
  }

  @override
  void dispose() {
    if (Platform.isIOS) TlNative.onDropped = null;
    super.dispose();
  }

  void _dropped(List<String> paths) {
    unawaited(widget.shares.importDropped(paths).catchError((Object e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(L('share.failed', ['$e']))));
    }));
  }

  @override
  Widget build(BuildContext context) {
    final page = Stack(children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _over ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            child: ColoredBox(
              color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32),
              child: Center(
                child: Material(
                  key: const ValueKey('dropHint'),
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: const StadiumBorder(),
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.file_download_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Text(L('drop.hint'), style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
    if (Platform.isIOS) return page;
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) {
        setState(() => _over = false);
        _dropped([for (final f in d.files) f.path]);
      },
      child: page,
    );
  }
}
