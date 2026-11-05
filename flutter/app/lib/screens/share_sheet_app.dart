import 'dart:convert';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import '../platform/share_inbox.dart';
import 'share_sheet.dart';

/// Only the share page, on a see-through window over the app that shared (Android's
/// `ShareSheetActivity`). It reads the folders the app last wrote and leaves its answer in the
/// inbox: this engine never opens the library.
class ShareSheetApp extends StatelessWidget {
  const ShareSheetApp({super.key, required this.id, required this.root, required this.theme});
  final String id;
  final String root;
  final ThemeData Function(Brightness, ColorScheme?) theme;

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
        builder: (light, dark) => MaterialApp(
          debugShowCheckedModeBanner: false,
          color: Colors.transparent,
          locale: AppLocale.current,
          supportedLocales: AppLocale.supported,
          localizationsDelegates: AppLocale.delegates,
          theme: theme(Brightness.light, light),
          darkTheme: theme(Brightness.dark, dark),
          home: _Host(id: id, root: root),
        ),
      );
}

class _Host extends StatefulWidget {
  const _Host({required this.id, required this.root});
  final String id;
  final String root;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  Future<void> _show() async {
    final inbox = ShareInbox(root: Directory(widget.root), asks: false);
    final batch = await inbox.partialBatch(widget.id);
    if (batch != null && mounted) {
      await presentShareSheet(
        context,
        shares: inbox,
        batch: batch,
        folders: await _folders(),
        confirm: inbox.publishChosen,
      );
    }
    await SystemNavigator.pop();
  }

  Future<List<String>> _folders() async {
    try {
      return (jsonDecode(await File('${widget.root}/folders.json').readAsString()) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(backgroundColor: Colors.transparent);
}
