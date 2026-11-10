// Standalone validation host; does not modify or depend on the parallel UI.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import 'seed.dart';
import '../platform/os.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await L10n.load();
  final path =
      OS.environment['TL_LIBRARY_DIR'] ??
      (await getApplicationSupportDirectory()).path;
  await Directory(path).create(recursive: true);
  Core.setLanguage(L10n.languageTag);
  if (!Core.open(path)) throw const CoreError('app.openFailed');
  await seedIfRequested();
  final stats = Core.stats();
  // Counts only: no user data, paths, credentials or VM-service tokens.
  debugPrint(
    'seed-smoke posts=${stats.posts} photos=${stats.photos} videos=${stats.videos}',
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            L('activity.stats', [stats.posts, stats.photos, stats.videos]),
          ),
        ),
      ),
    ),
  );
}
