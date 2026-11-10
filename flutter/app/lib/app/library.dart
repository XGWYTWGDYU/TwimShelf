import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../dev/seed.dart';
import '../grid/thumb_store.dart';
import '../platform/secrets.dart';
import '../platform/lease.dart';
import '../services/extension_receiver.dart';
import 'prefs.dart';
import '../platform/quick_action.dart';
import '../platform/share_inbox.dart';
import '../l10n/l10n.dart';
import '../ai/auto_tagger.dart';
import '../ai/local_models.dart';
import '../ai/external_models.dart';
import '../services/downloads.dart';
import 'jobs.dart';
import 'sync_model.dart';
import '../platform/os.dart';

/// The open library, shared by every screen: opening it, its counts and folders, and a
/// `revision` that moves whenever its content changed (an action here, an import, a sync from
/// another device), so lists reload. Core calls that can take time run off the UI isolate.
class LibraryModel extends ChangeNotifier {
  LibraryModel._(this.directory);

  final String directory;
  /// Grid thumbnails, shared by every grid.
  late final ThumbStore thumbs;
  LibraryStats? stats;
  FolderOverview? folders;

  /// Moves whenever the library changed; screens reload what they show.
  int revision = 0;
  /// A post to show in 浏览 (a grid's 在浏览中查看帖子): the shell goes to 浏览, which
  /// brings the post to the top and marks it.
  final revealRequest = ValueNotifier<FeedItem?>(null);
  void reveal(FeedItem item) => revealRequest.value = item;
  /// 在浏览中查看: 浏览 with this filter (a grid's kind, folder, collection).
  final filterRequest = ValueNotifier<FeedFilter?>(null);
  /// 浏览 tapped twice on a phone's bar: a new random order.
  final shuffleRequest = ValueNotifier<int>(0);
  void showInBrowse(FeedFilter f) => filterRequest.value = f;

  /// Shares from other apps waiting to come in.
  late final ShareInbox shares;
  StreamSubscription<ShareInboxEvent>? _shareEvents;
  int _epoch = -1;
  final SyncModel sync = SyncModel();
  /// 下载帖子: the durable link queue and the core's download job.
  late final DownloadService downloads;
  /// Tagging with external models: the user's services, the client, the runner.
  late final ExternalModels aiModels;
  late final ExternalAI ai;
  late final AutoTagger tagger;
  Timer? _poll;

  /// Opens the library in the app's support folder, or `TL_LIBRARY_DIR` (test builds and the
  /// desktop tests point it at a synthetic library; the user's real one is never used there).
  /// For a test that opened its own synthetic library with the core.
  @visibleForTesting
  static LibraryModel forTest(String dir) => LibraryModel._(dir);

  static Future<LibraryModel> open() async {
    final String dir;
    if (OS.isWeb) {
      // the web build: the library is the server's (it opened it already)
      dir = (await loadServerInfo()).library;
    } else {
      final override = OS.environment['TL_LIBRARY_DIR'];
      dir = override ?? '${(await getApplicationSupportDirectory()).path}${OS.pathSeparator}Library';
      await Directory(dir).create(recursive: true);
    }
    final language = L10n.languageTag;
    final ok = await openLibrary(language, dir);
    if (!ok) throw CoreError(L('app.openFailed'));
    // a debug build started with a synthetic seed fills the (empty) test library first
    await seedIfRequested();
    // the download cookies, from the platform's secret store
    await Session.applyStoredCookies();
    final m = LibraryModel._(dir);
    m.thumbs = await ThumbStore.create();
    // what cannot be decoded joins 只看损坏 and the check's count (a format this core has no decoder
    // for only has its file checked)
    m.thumbs.onFailed = (id) => unawaited(coreRunAsync(() => Core.reportThumbnailFailed(id)).catchError((Object _) {}));
    // shares from other apps (Android today): files are imported, links wait in the queue for
    // the download flow (they are acknowledged there, so none is lost)
    m.shares = ShareInbox(asks: !OS.isIOS && !OS.isMacOS);
    m._shareEvents = m.shares.events.listen((e) {
      if (e is ShareQuickDownload) QuickAction.request();
      if (e is ShareFilesImported) m.refresh();
    });
    m.aiModels = await ExternalModels.create();
    m.ai = ExternalAI(m.aiModels);
    m.tagger = AutoTagger(models: m.aiModels, ai: m.ai, cacheDirectory: '$dir${OS.pathSeparator}.ai',
        // the tags it wrote show, and reach the other devices; tagging itself is already going
        onChanged: () => unawaited(m.refresh(startTagging: false)));
    // on-device models (MLX on Apple devices, llama.cpp elsewhere): a missing engine only hides them
    try {
      await LocalModels.instance.start();
      // a tagger is chosen when one is installed and none is, or the chosen one has gone
      void adopt() => unawaited(m.aiModels.adoptInstalled(LocalModels.instance).catchError((Object _) {}));
      LocalModels.instance.addListener(adopt);
      adopt();
    } catch (_) {}
    // the first counts (opening is no change to announce)
    await m.refresh(local: false);
    m.downloads = await DownloadService.create(libraryDirectory: OS.isWeb ? null : Directory(dir), libraryPath: dir, onFinished: (_) => m.refresh());
    // the browser extension sends links here (the desktop apps; the server listens on its own)
    ExtensionReceiver.instance.start(m.downloads);
    // shared links go into the download queue durably before the share is acknowledged
    await m.downloads.attachShareInbox(m.shares);
    unawaited(m.shares.start());
    // a wipe (from another window, a test) is noticed by the core's epoch
    m._poll = Timer.periodic(const Duration(seconds: 1), (_) => m._checkEpoch());
    // another device's changes: reload, without announcing them as this device's
    m.sync.remoteChanges.addListener(() => m.refresh(local: false));
    // the web app open in several windows: one runs the background work, the next takes over
    BackgroundLease.instance.addListener(() {
      if (BackgroundLease.instance.holder) unawaited(m.tagger.startIfEnabled().catchError((Object _) {}));
    });
    unawaited(BackgroundLease.instance.start());
        // LAN sync with the account's other devices (off in test runs that ask for it)
    if (OS.environment['TL_SYNC_OFF'] == null) unawaited(m.sync.start());
    return m;
  }

  Future<void> _checkEpoch() async {
    final e = Core.epoch();
    // the epoch counts wipes (work started before one can no longer write), not changes
    if (e != _epoch) {
      _epoch = e;
      await refresh();
    }
  }

  /// Reloads counts and folders and tells the screens to reload. A change made here (the
  /// default) is also announced to the account's other devices, which sync in a few seconds.
  Future<void> refresh({bool local = true, bool startTagging = true}) async {
    if (local) SyncModel.localChange();
    // new media (a download, a sync) get tagged when tagging is on
    if (startTagging) unawaited(tagger.startIfEnabled().catchError((_) {}));
    final (s, f) = await loadCounts();
    stats = s;
    folders = f;
    _epoch = Core.epoch();
    unawaited(shares.publishFolders([for (final x in f.folders) x.name]).catchError((_) {}));
    revision++;
    notifyListeners();
  }

  /// Before the data folder moves: nothing downloads, tags or syncs while it is copied. The app
  /// restarts afterwards.
  Future<void> stopWriting() async {
    await tagger.stopForWipe();
    await downloads.pauseForMove();
    Core.discoveryStop();
  }

  /// 清除所有数据, as the native apps: what the core keeps, and what this app keeps around it (the
  /// download queue, shares waiting, the sync account, cookies and API keys, settings). The AI
  /// settings stay unless the models go too. Gives back what could not be removed.
  Future<List<String>> wipeEverything({required bool includeModels}) async {
    final problems = <String>[];
    await tagger.stopForWipe();
    await downloads.discardAll();
    await LocalModels.instance.unload();
    await Core.wipeAsync(includeModels: includeModels);
    await shares.wipe();
    Core.setCookies('', '');
    for (final key in ['auth_token', 'ct0']) {
      if (await Secrets.delete(key) is SecretsUnavailable) problems.add(L('secrets.unavailable'));
    }
    await aiModels.forget(settings: includeModels);
    if (!await sync.forgetAccount()) problems.add(L('secrets.unavailable'));
    await Prefs.instance.wipe(keepAI: !includeModels);
    LocalModels.instance.refresh();
    await refresh(local: false);
    return problems.toSet().toList();
  }

  /// The media a grid or 浏览 shows.
  Future<List<FeedItem>> feed(FeedRequest request) => loadFeed(request);

  @override
  void dispose() {
    _poll?.cancel();
    sync.dispose();
    downloads.dispose();
    thumbs.dispose();
    unawaited(tagger.close());
    ai.close();
    _shareEvents?.cancel();
    shares.dispose();
    super.dispose();
  }
}
