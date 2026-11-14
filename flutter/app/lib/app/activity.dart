import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tl_core/tl_core.dart';

import '../ai/local_models.dart';
import '../l10n/l10n.dart';
import '../services/downloads.dart';
import 'library.dart';

/// What the progress card is about (as the native apps' `Activity.Kind`).
enum ActivityKind { download, model, tagging, sync, verify, importing }

/// One running task the panel shows (the native apps' `Activity`).
@immutable
class Activity {
  const Activity({required this.kind, required this.title, required this.detail, this.progress, this.previewPath, this.previewIsVideo = false});
  final ActivityKind kind;
  final String title;
  final String detail;
  /// 0…1, or null while it cannot be told.
  final double? progress;
  /// The item being worked on (a photo or video of the library), for the card's picture.
  final String? previewPath;
  final bool previewIsVideo;

  /// A stopped worker is no proof of success: only an explicit success fills the bar.
  Activity ended(String outcome, {String? detail, double? progress}) {
    final prefix = switch (outcome) {
      'succeeded' => L('activity.done'),
      'partial' => L('activity.partial'),
      'failed' => L('activity.failed'),
      'cancelled' => L('models.cancelled'),
      'paused' => L('activity.paused'),
      _ => L('activity.stopped'),
    };
    return Activity(
      kind: kind,
      title: '$prefix · ${title.replaceAll(L('activity.running'), '')}',
      detail: detail ?? this.detail,
      progress: outcome == 'succeeded' ? 1 : (progress ?? this.progress),
      previewPath: previewPath,
      previewIsVideo: previewIsVideo,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Activity && other.kind == kind && other.title == title && other.detail == detail && other.progress == progress &&
      other.previewPath == previewPath && other.previewIsVideo == previewIsVideo;

  @override
  int get hashCode => Object.hash(kind, title, detail, progress, previewPath, previewIsVideo);
}

bool _isVideoPath(String p) {
  final l = p.toLowerCase();
  return l.endsWith('.mp4') || l.endsWith('.mov') || l.endsWith('.m4v');
}

String _bytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']; // i18n-exempt: unit symbols
  var v = b.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
}

/// Every source of background work in one list, for the floating progress panel on every page
/// (the native apps' `ActivityCenter`): downloads, model downloads, AI tagging, sync, imports and
/// the integrity check. Downloads, tagging, sync and model downloads tell when they change; the
/// core's import and check are asked once a second, off the UI thread, and only those two.
class ActivityCenter extends ChangeNotifier {
  ActivityCenter(this.library) {
    library.downloads.addListener(_rebuild);
    library.tagger.addListener(_rebuild);
    library.sync.addListener(_rebuild);
    LocalModels.instance.addListener(_rebuild);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollCore());
    _pollCore();
  }

  final LibraryModel library;
  Timer? _poll;
  ImportProgress? _import;
  VerifyStatus? _verify;
  bool _polling = false;

  List<Activity> get activities => _shown;
  List<Activity> _shown = const [];

  Future<void> _pollCore() async {
    if (_polling) return;
    _polling = true;
    try {
      final (i, v) = await coreRunAsync(() => (Core.importStatus(), Core.verifyStatus()));
      _import = i;
      _verify = v;
      _rebuild();
    } catch (_) {
      // a core call that failed: nothing to show for it this time
    } finally {
      _polling = false;
    }
  }

  List<Activity> _running() {
    final list = <Activity>[];
    final d = library.downloads.status;
    if (d != null && d.running) {
      final recent = d.recent.isEmpty ? null : d.recent.last;
      list.add(Activity(
        kind: ActivityKind.download,
        title: L('activity.downloadingPosts'),
        detail: '${d.done + d.skipped + d.failed} / ${d.total}'
            '${d.failed > 0 ? L('settings.failedSuffix', [d.failed]) : ''}'
            '${d.active.isEmpty ? '' : L('activity.activeSuffix', [d.active.length])}',
        progress: d.total > 0 ? (d.done + d.skipped + d.failed) / d.total : null,
        previewPath: recent,
        previewIsVideo: recent != null && _isVideoPath(recent),
      ));
    }
    final m = LocalModels.instance.download;
    if (m != null && m.running) {
      list.add(Activity(
        kind: ActivityKind.model,
        title: L('activity.downloadingModel', [m.repo.split('/').last]),
        detail: '${_bytes(m.done_bytes)} / ${_bytes(m.total_bytes)}',
        progress: m.total_bytes > 0 && !m.verifying ? m.done_bytes / m.total_bytes : null,
      ));
    }
    final t = library.tagger;
    if (t.running && !t.paused) {
      final total = t.total > t.done ? t.total : t.done;
      list.add(Activity(
        kind: ActivityKind.tagging,
        title: t.title,
        detail: '${t.done} / $total',
        progress: t.total > 0 ? t.done / t.total : null,
        previewPath: t.currentPath,
        previewIsVideo: t.currentKind == 'video',
      ));
    }
    final s = library.sync.status;
    if (s != null && s.syncing > 0) {
      final r = s.receiving;
      if (r != null && r.total > 0) {
        final inFlight = r.current_size > 0 ? r.current_done / r.current_size : 0.0;
        final left = r.total > r.received ? r.total - r.received : 0;
        var detail = L('activity.filesLeft', [left]);
        if (r.total_bytes > 0) {
          detail += ' · ${_bytes(r.total_bytes > r.bytes ? r.total_bytes - r.bytes : 0)}';
          detail += L('activity.received', [r.received, r.total, _bytes(r.bytes), _bytes(r.total_bytes)]);
        } else {
          detail += L('activity.receivedShort', [r.received, r.total, _bytes(r.bytes)]);
        }
        if (r.current_size > 8000000) detail += L('activity.currentFile', [(inFlight * 100).round()]);
        list.add(Activity(
          kind: ActivityKind.sync,
          title: L('activity.receiving'),
          detail: detail,
          progress: (r.total_bytes > 0 ? r.bytes / r.total_bytes : (r.received + inFlight) / r.total).clamp(0.0, 1.0),
        ));
      } else {
        list.add(Activity(kind: ActivityKind.sync, title: L('activity.syncing'), detail: L('activity.syncDetail')));
      }
    }
    final i = _import;
    if (i != null && i.running) {
      list.add(Activity(
        kind: ActivityKind.importing,
        title: i.waiting ? L('activity.importWaiting') : L('activity.importing'),
        detail: L('activity.importProgress', [i.folders_done, i.folders_total, i.files_done]) +
            (i.issues > 0 ? L('activity.importIssues', [i.issues]) : ''),
        progress: i.folders_total > 0 ? i.folders_done / i.folders_total : null,
        previewPath: i.current,
        previewIsVideo: i.current != null && _isVideoPath(i.current!),
      ));
    }
    final v = _verify;
    if (v != null && v.running) {
      list.add(Activity(
        kind: ActivityKind.verify,
        title: L('activity.verifying'),
        detail: '${v.checked} / ${v.total} · ${_bytes(v.bytes)}${v.bad > 0 ? L('activity.foundBad', [v.bad]) : ''}',
        progress: v.total > 0 ? v.checked / v.total : null,
        previewPath: v.current,
        previewIsVideo: v.current != null && _isVideoPath(v.current!),
      ));
    }
    return list;
  }

  // A card stays at least two seconds, so it is never gone before it can be read: work that ends
  // sooner keeps its real outcome for the rest of that time, and at least a moment.
  final _since = <ActivityKind, DateTime>{};
  final _last = <ActivityKind, Activity>{};
  final _until = <ActivityKind, DateTime>{};
  Timer? _expire;
  static const _minimumShown = Duration(seconds: 2);

  void _rebuild() {
    final now = DateTime.now();
    final running = _running();
    final out = [...running];
    final live = {for (final a in running) a.kind};
    for (final a in running) {
      if (_since[a.kind] == null || _until[a.kind] != null) _since[a.kind] = now;
      _until.remove(a.kind);
      _last[a.kind] = a;
    }
    for (final kind in [..._last.keys]) {
      if (live.contains(kind)) continue;
      _until[kind] ??= () {
        final hold = (_since[kind] ?? now).add(_minimumShown);
        final moment = now.add(const Duration(milliseconds: 1200));
        return hold.isAfter(moment) ? hold : moment;
      }();
      if (now.isBefore(_until[kind]!)) {
        out.add(_completed(_last[kind]!));
      } else {
        _last.remove(kind);
        _until.remove(kind);
        _since.remove(kind);
      }
    }
    // a finished card goes when its time is up, even if nothing else changes meanwhile
    _expire?.cancel();
    if (_until.isNotEmpty) {
      final next = _until.values.reduce((a, b) => a.isBefore(b) ? a : b);
      _expire = Timer(next.difference(now) + const Duration(milliseconds: 20), _rebuild);
    }
    if (!listEquals(out, _shown)) {
      _shown = out;
      notifyListeners();
    }
  }

  Activity _completed(Activity last) {
    switch (last.kind) {
      case ActivityKind.download:
        final d = library.downloads.status;
        if (d == null) return last.ended('stopped');
        final outcome = library.downloads.phase == DownloadPhase.paused ? 'paused' : d.outcome;
        return last.ended(outcome,
            detail: L('activity.downloadSummary', [d.done, d.skipped, d.failed, d.total]),
            progress: d.total > 0 ? (d.done + d.skipped + d.failed) / d.total : null);
      case ActivityKind.model:
        final m = LocalModels.instance.download;
        if (m == null) return last.ended('stopped');
        return last.ended(m.finished ? 'succeeded' : (m.error == L('models.cancelled') ? 'cancelled' : 'failed'),
            detail: m.error, progress: m.total_bytes > 0 ? m.done_bytes / m.total_bytes : null);
      case ActivityKind.tagging:
        final t = library.tagger;
        return last.ended(t.paused ? 'paused' : t.outcome, detail: '${t.done} / ${t.total}', progress: t.total > 0 ? t.done / t.total : null);
      case ActivityKind.importing:
        final i = _import;
        if (i == null) return last.ended('stopped');
        return last.ended(i.outcome,
            detail: L('activity.importSummary', [i.folders_done, i.folders_total, i.files_done, i.issues]),
            progress: i.folders_total > 0 ? i.folders_done / i.folders_total : null);
      case ActivityKind.verify:
        final v = _verify;
        if (v == null) return last.ended('stopped');
        return last.ended(v.outcome, detail: L('activity.verifySummary', [v.checked, v.total, v.bad]), progress: v.total > 0 ? v.checked / v.total : null);
      case ActivityKind.sync:
        // no overall success signal for a sync session: the state, without claiming every
        // device or file has arrived
        return Activity(kind: ActivityKind.sync, title: _syncState(), detail: L('activity.syncSeePage'));
    }
  }

  /// The sync's state after a session (as the native apps' `SyncService.stateText`).
  String _syncState() {
    final s = library.sync.status;
    if (s == null) return L('sync.state.reading');
    if (s.failed.isNotEmpty || s.peers.any((p) => p.last_error != null)) return L('sync.state.failed');
    final last = s.peers.fold<int>(0, (m, p) => p.last_sync > m ? p.last_sync : m);
    if (last > 0) {
      final t = DateTime.fromMillisecondsSinceEpoch(last * 1000);
      return '${L('sync.state.lastOK')}${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return L('sync.state.waiting');
  }

  @override
  void dispose() {
    _poll?.cancel();
    _expire?.cancel();
    library.downloads.removeListener(_rebuild);
    library.tagger.removeListener(_rebuild);
    library.sync.removeListener(_rebuild);
    LocalModels.instance.removeListener(_rebuild);
    super.dispose();
  }
}

/// Pages that fill the window (the media viewer) count themselves here: the progress panel
/// steps aside while one is open.
final immersivePages = ValueNotifier<int>(0);
