import 'identity.g.dart';

import 'package:tl_core/tl_core.dart';

// Core calls that run off the UI isolate. Each is a top-level function of plain values: a
// closure made inside a method or a widget's state carries that scope's other captured objects
// along (timers, streams, the library model), which cannot be sent to another isolate.

Future<bool> openLibrary(String language, String dir) => coreRunAsync(() {
      Core.setLanguage(language);
      Core.setAppName(appName);
      return Core.open(dir);
    });

Future<(LibraryStats, FolderOverview)> loadCounts() => coreRunAsync(() => (Core.stats(), Core.folderOverview()));

Future<List<FeedItem>> loadFeed(FeedRequest request) => coreRunAsync(() => Core.feed(request));

Future<List<FeedItem>> loadBin() => coreRunAsync(() => Core.trashList()
    .map((t) => FeedItem(
        media_id: t.media_id, post_id: t.post_id, ordinal: t.ordinal, kind: t.kind, path: t.path,
        text: t.text, author_name: t.author_name, screen_name: t.screen_name, url: t.url, tags: t.tags))
    .toList());

Future<CookieCheck> checkCookies(String auth, String ct0) => coreRunAsync(() => Core.checkCookies(auth, ct0));

Future<StorageUsage> loadStorageUsage(Map<String, List<String>> places) => coreRunAsync(() => Core.storageUsage(places));

Future<int?> loadFreeSpace(String path) => coreRunAsync(() => Core.freeSpace(path));

Future<int> emptyTrashOff() => coreRunAsync(Core.emptyTrash);

Future<List<String>> loadBookmarkURLs(String path) => coreRunAsync(() => Core.bookmarkURLs(path));

Future<String> createFolder(String name) => coreRunAsync(() => Core.createFolder(name));

/// Puts every media of a tag into a folder (made first when missing); the number moved.
Future<int> tagToFolder(String label, String folder, {required bool create}) => coreRunAsync(() {
      if (create) Core.createFolder(folder);
      return Core.tagToFolder(label, folder);
    });
