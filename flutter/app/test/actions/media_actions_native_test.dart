import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';

// Optional real-core regression: only generated fixtures and a fresh temporary library.
// TL_TEST_CORE_DYLIB supplies a macOS dylib linked from the app's Rust static library;
// TL_TEST_IMPORT_DIR supplies scripts/make_seed.py's posts directory.
void main() {
  final dylib = Platform.environment['TL_TEST_CORE_DYLIB'];
  final fixtures = Platform.environment['TL_TEST_IMPORT_DIR'];
  test('worker actions trash media and whole posts, undo, snapshot and purge', () async {
    final open = DynamicLibrary.process().lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
    final name = dylib!.toNativeUtf8();
    try {
      // RTLD_NOW | RTLD_GLOBAL: Core resolves process symbols in every isolate.
      expect(open(name, 0x2 | 0x8), isNot(nullptr));
    } finally {
      calloc.free(name);
    }
    final root = await Directory.systemTemp.createTemp('twim-actions-test-');
    addTearDown(() => root.delete(recursive: true));
    expect(Core.open(root.path), isTrue);
    Core.importLegacyDirectory(fixtures!);
    final before = Core.feed(FeedRequest(seed: 1));
    expect(before, isNotEmpty);
    final media = before.first.media_id;
    final receipt = await Core.actionAsync(ActionKind.trash, media: [media]);
    expect(receipt.changes, hasLength(1));
    expect(Core.feed(FeedRequest()).any((i) => i.media_id == media), isFalse);
    expect(Core.undo(receipt), 1);
    expect(Core.feed(FeedRequest()).length, before.length);

    final post = before.first.post_id;
    final ids = before.where((i) => i.post_id == post).map((i) => i.media_id).toList();
    // Undo a whole-post addition without removing an existing tag on one media.
    Core.action(ActionKind.tag, media: [media], label: 'picker-undo');
    final tags = Core.action(ActionKind.tag, posts: [post], label: 'picker-undo');
    Core.undo(tags);
    final scope = Core.postScope(post);
    expect(scope.user_tags[media], contains('picker-undo'));
    for (final id in ids.where((id) => id != media)) {
      expect(scope.user_tags[id] ?? [], isNot(contains('picker-undo')));
    }
    final singleTag = Core.action(ActionKind.tag, media: [media], label: 'picker-new');
    expect(Core.undo(singleTag), 1);
    expect(Core.postScope(post).user_tags[media], isNot(contains('picker-new')));

    final trashed = await Core.actionAsync(ActionKind.trash, posts: [post]);
    expect(trashed.changes.length, ids.length);
    expect(Core.feed(FeedRequest()).any((i) => i.post_id == post), isFalse);
    final snapshot = await Core.binSnapshotAsync(media: ids);
    expect(snapshot.entries.length, ids.length);
    final restored = await Core.actionAsync(ActionKind.restore, media: ids);
    expect(restored.changes.length, ids.length);
    expect(Core.feed(FeedRequest()).length, before.length);
    // A stale purge snapshot must not remove restored media.
    expect((await Core.actionAsync(ActionKind.purge, media: ids, snapshot: snapshot)).changes, isEmpty);
    expect(Core.feed(FeedRequest()).length, before.length);
  }, skip: !Platform.isMacOS || dylib == null || fixtures == null);
}
