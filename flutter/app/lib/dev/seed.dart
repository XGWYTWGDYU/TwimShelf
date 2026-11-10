import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import '../platform/os.dart';

/// Call after Core.open, before the first feed/stats refresh. Entire body is
/// eliminated in profile/release. Fixtures are external, never release assets.
Future<void> seedIfRequested() async {
  if (!kDebugMode) return;
  const enabled =
      bool.fromEnvironment('TL_SEED') ||
      String.fromEnvironment('TL_SEED') == '1';
  final source =
      OS.environment['TL_IMPORT_DIR'] ??
      const String.fromEnvironment('TL_IMPORT_DIR');
  if (source.isEmpty && !enabled) return;
  final support =
      OS.environment['TL_LIBRARY_DIR'] ??
      (await getApplicationSupportDirectory()).path;
  final input = source.isNotEmpty
      ? source
      : '${(await getApplicationDocumentsDirectory()).path}/seed';
  final marker = File('$support/.synthetic-seed-v1');
  if (await marker.exists()) return;
  if (!await File('$input/seed.json').exists()) {
    throw const FileSystemException('dev.seed.missingManifest');
  }
  final manifest = jsonDecode(
    await File('$input/seed.json').readAsString(),
  ) as Map<String, dynamic>;
  final hashes = manifest['sha256'] as Map<String, dynamic>;
  final damaged = hashes.entries
      .where((entry) => entry.key.endsWith('/damaged.png'))
      .map((entry) => entry.value as String)
      .toList();
  await coreRunAsync(() {
    // Never seed a pre-existing personal library, even if a test launch forgot
    // its directory override. A previous successful seed returns at the marker.
    final before = Core.stats();
    if (before.posts != 0 ||
        before.photos != 0 ||
        before.videos != 0 ||
        before.trashed != 0) {
      throw const CoreError('dev.seed.requiresEmptyLibrary');
    }
    Core.importLegacyDirectory('$input/posts');
    Core.importLooseDir('$input/loose', consume: false);
    final items = Core.feed(FeedRequest(seed: 1));
    if (items.isEmpty) throw const CoreError('dev.seed.empty');
    for (var i = 0; i < items.length; i++) {
      final id = items[i].media_id;
      // Synthetic fixture content, not application UI strings.
      if (i % 3 != 1) Core.addTag('Seed · mine', id);
      if (i % 3 != 0) {
        Core.aiApply(
          mediaId: id,
          model: 'synthetic-seed',
          labels: ['Seed · AI'],
        );
      }
      if (i % 3 == 2) Core.addTag('Seed · AI', id);
    }
    Core.createFolder('Seed · collection');
    Core.addToFolder(
      'Seed · collection',
      media: items.take(4).map((item) => item.media_id).toList(),
    );
    for (final item in items.where((item) => damaged.contains(item.media_id))) {
      final file = File(item.path);
      final libraryRoot = '${Directory(support).absolute.path}/';
      if (!file.absolute.path.startsWith(libraryRoot)) {
        throw const FileSystemException('dev.seed.outsideLibrary');
      }
      // Deliberately damage only our manifest-identified synthetic blob.
      file.writeAsBytesSync([0, 1, 2, 3], flush: true);
      Core.reportBad(item.media_id);
    }
    final binCandidates = items.where(
      (item) => item.post_id.isNotEmpty && !damaged.contains(item.media_id),
    );
    if (items.length > 4 && binCandidates.isNotEmpty) {
      Core.trash(media: [binCandidates.last.media_id]);
    }
  });
  await marker.parent.create(recursive: true);
  final pending = File('${marker.path}.partial');
  await pending.writeAsString('1\n', flush: true);
  await pending.rename(marker.path);
}
