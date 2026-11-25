import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import '../platform/video.dart';
import 'external_models.dart';
import 'local_models.dart';
import '../widgets/media_image.dart';
import '../platform/os.dart';

abstract interface class TaggingCore {
  Future<int> epoch();
  Future<({int done, int total})> counts();
  Future<int> failures();
  Future<List<MediaRef>> pending(String model, int since, int limit);
  Future<List<MediaRef>> page(String after, int limit);
  Future<List<String>> vocabulary();
  Future<List<String>> existing(String media);
  Future<void> attempt(
    AiAttemptStep step,
    String media,
    String model, {
    String reason = '',
  });
  Future<void> apply(
    String media,
    String model,
    List<String> labels,
    bool replace,
    int epoch,
  );
}

// Top-level helpers capture only sendable values, never a ChangeNotifier/client.
Future<int> _epoch() => coreRunAsync(Core.epoch);
Future<({int done, int total})> _counts() => coreRunAsync(Core.aiCounts);
Future<int> _failures() => coreRunAsync(() => Core.aiFailures().length);
Future<List<MediaRef>> _pending(String model, int since, int limit) =>
    coreRunAsync(() => Core.aiPendingFor(model, since, limit));
Future<List<MediaRef>> _page(String after, int limit) =>
    coreRunAsync(() => Core.mediaPage(after, limit));
Future<List<String>> _vocabulary() =>
    coreRunAsync(() => Core.allTags().take(150).map((t) => t.label).toList());
Future<List<String>> _existing(String media) =>
    coreRunAsync(() => Core.mediaTags(media));
Future<void> _attempt(
  AiAttemptStep step,
  String media,
  String model,
  String reason,
) => coreRunAsync(
  () => Core.aiAttempt(step, mediaId: media, model: model, reason: reason),
);
Future<void> _apply(
  String media,
  String model,
  List<String> labels,
  bool replace,
  int epoch,
) => coreRunAsync(
  () => Core.aiApply(
    mediaId: media,
    model: model,
    labels: labels,
    replaceOld: replace,
    atEpoch: epoch,
  ),
);

class NativeTaggingCore implements TaggingCore {
  @override
  Future<int> epoch() => _epoch();
  @override
  Future<({int done, int total})> counts() => _counts();
  @override
  Future<int> failures() => _failures();
  @override
  Future<List<MediaRef>> pending(String model, int since, int limit) =>
      _pending(model, since, limit);
  @override
  Future<List<MediaRef>> page(String after, int limit) => _page(after, limit);
  @override
  Future<List<String>> vocabulary() => _vocabulary();
  @override
  Future<List<String>> existing(String media) => _existing(media);
  @override
  Future<void> attempt(
    AiAttemptStep step,
    String media,
    String model, {
    String reason = '',
  }) => _attempt(step, media, model, reason);
  @override
  Future<void> apply(
    String media,
    String model,
    List<String> labels,
    bool replace,
    int epoch,
  ) => _apply(media, model, labels, replace, epoch);
}

/// The picture of [media] as a file the core can read: a photo as it is, a HEIF one decoded, a
/// frame of a video (the player takes it). The core prepares it for the model.
Future<String?> taggingPicture(MediaRef media, String cacheDirectory) async {
  if (media.kind == 'video') {
    return videoPoster(
      FeedItem(
        media_id: media.media_id,
        post_id: '',
        ordinal: 0,
        kind: MediaKind.video,
        path: media.path,
        tags: const [],
      ),
      896,
      cacheDirectory,
    );
  }
  if (isHeifPath(media.path)) {
    try {
      return await Core.displayImageAsync(media.path, 896, cacheDirectory);
    } on CoreError {
      return null;
    }
  }
  return media.path;
}

enum TaggingScope { untagged, media, all }

class TaggingJob {
  const TaggingJob({
    required this.model,
    this.scope = TaggingScope.untagged,
    this.media = const [],
    this.replaceOld = false,
    this.resumeAfter = '',
    this.doneBefore = 0,
  });
  final String model, resumeAfter;
  final TaggingScope scope;
  final List<MediaRef> media;
  final bool replaceOld;
  final int doneBefore;
  bool get libraryRun => scope != TaggingScope.media;
  String get identity =>
      '$model/${scope.name}/$replaceOld/$resumeAfter/$doneBefore/${media.map((m) => m.media_id).join(',')}';
  /// What is left of this job. [handled]: how many of its selected media are through.
  TaggingJob resume(String after, int done, {int handled = 0}) => TaggingJob(
    model: model,
    scope: scope,
    media: media.sublist(handled.clamp(0, media.length)),
    replaceOld: replaceOld,
    resumeAfter: scope == TaggingScope.all ? after : '',
    doneBefore: scope == TaggingScope.all ? done : 0,
  );
}

typedef TaggingImageLoader = Future<String?> Function(MediaRef);

/// Something that went wrong outside the model's own answer (the core refused a write, a read
/// failed): a run that ends on it says what it was, not only "didn't finish", and the log has it
/// (logcat and the console show it in release builds too).
ExternalFailure unexpectedFailure(Object error, [StackTrace? stack]) {
  debugPrint('auto tagger: $error${stack == null ? '' : '\n$stack'}');
  final text = error is CoreError ? error.message : '$error';
  return ExternalFailure(
    ExternalFailureKind.transport,
    detail: text.length > 200 ? '${text.substring(0, 200)}…' : text,
  );
}
/// The model a run uses: an external service, or an installed on-device model.
class TaggingModel {
  TaggingModel.external(ExternalModel this.external) : id = external.id, title = external.title;
  const TaggingModel.local({required this.id, required this.title}) : external = null;
  final String id, title;
  final ExternalModel? external;
}

/// The tags for the picture at a path (see [coreTags]).
typedef TaggingInference = Future<List<String>> Function(
  TaggingModel,
  String,
  List<String>,
  List<String>,
  String?,
  AiCancellation,
);

/// One owner per open library. Close it BEFORE switching Core.open to another
/// library. External calls run asynchronously; all core/image CPU work is off UI.
class AutoTagger extends ChangeNotifier {
  AutoTagger({
    required this.models,
    required this.ai,
    required String cacheDirectory,
    TaggingCore? core,
    TaggingImageLoader? imageLoader,
    TaggingInference? infer,
    DateTime Function()? now,
    this.onChanged,
  }) : core = core ?? NativeTaggingCore(),
       _image =
           imageLoader ??
           ((media) => taggingPicture(media, cacheDirectory)),
       _infer =
           infer ??
           ((model, picture, existing, vocabulary, text, cancellation) async => coreTags(
                 model.external != null ? await ai.service(model.external!) : {'kind': 'local', 'id': model.id},
                 image: picture,
                 existing: existing,
                 vocabulary: vocabulary,
                 postText: text,
                 cancellation: cancellation,
               )),
       _now = now ?? DateTime.now {
    // iOS ends an app that keeps the GPU busy in the background, as the native apps know
    if (OS.isIOS) {
      _lifecycle = AppLifecycleListener(
        onHide: () {
          if (_paused || !running) return;
          _pausedForBackground = true;
          pause();
        },
        onShow: () {
          if (!_pausedForBackground) return;
          _pausedForBackground = false;
          resume();
        },
      );
    }
  }
  AppLifecycleListener? _lifecycle;
  bool _pausedForBackground = false;
  final ExternalModels models;
  final ExternalAI ai;
  final TaggingCore core;
  final TaggingImageLoader _image;
  final TaggingInference _infer;
  final DateTime Function() _now;
  final void Function()? onChanged;
  final List<TaggingJob> _queue = [];
  final Set<String> _givenBack = {};
  TaggingJob? _current;
  AiCancellation? _cancellation;
  Future<void>? _task;
  bool _paused = false, _closed = false;
  /// 停止标记: no new automatic run until asked for, or the next launch. Without this, the next
  /// change to the library would start it again.
  bool _stopped = false;
  /// Of the selected media of the job running, how many are through (tagged or given up on).
  int _handled = 0;
  bool get running => _task != null;
  bool get paused => _paused;
  int done = 0, total = 0;
  String outcome = 'idle';
  String? currentPath;
  String currentKind = 'photo';
  String title = '';
  ExternalFailure? lastError;
  String _after = '';
  TaggingJob? _resumeMarker;
  Future<void> get settled async {
    while (_task != null) {
      await _task;
    }
  }

  void _post() {
    if (!_closed) notifyListeners();
  }

  /// An external model, or an installed on-device one (MLX on Apple devices, llama.cpp
  /// elsewhere).
  TaggingModel? _model(String id) {
    final e = models.find(id);
    if (e != null) return TaggingModel.external(e);
    final m = LocalModels.instance.find(id);
    return m != null && m.vision ? TaggingModel.local(id: m.id, title: LocalModels.instance.title(m)) : null;
  }

  /// [asked]: someone asked for it just now (a switch, another try), which ends a 停止标记.
  Future<void> startIfEnabled({bool asked = false}) async {
    if (asked) _stopped = false;
    if (_stopped) return;
    final id = models.activeTaggerId;
    if (_closed ||
        _paused ||
        running ||
        !models.autoTag ||
        id == null ||
        _model(id) == null) {
      return;
    }
    if ((await core.pending(id, 0, 1)).isNotEmpty &&
        !_closed &&
        !_paused &&
        !running) {
      start(TaggingJob(model: id));
    }
  }

  void start(TaggingJob job) {
    if (_closed) return;
    if (_model(job.model) == null) {
      lastError = const ExternalFailure(ExternalFailureKind.noModel);
      _post();
      return;
    }
    if (_queue.any((j) => j.identity == job.identity)) return;
    // Snapshot caller-owned lists before a job can outlive its caller.
    _queue.add(
      TaggingJob(
        model: job.model,
        scope: job.scope,
        media: List.unmodifiable(job.media),
        replaceOld: job.replaceOld,
        resumeAfter: job.resumeAfter,
        doneBefore: job.doneBefore,
      ),
    );
    _pump();
  }

  void retag(
    List<MediaRef> media, {
    required String model,
    bool replaceOld = false,
  }) {
    if (_closed) return;
    final job = TaggingJob(
      model: model,
      scope: TaggingScope.media,
      media: List.unmodifiable(media),
      replaceOld: replaceOld,
    );
    if (_model(model) == null) {
      lastError = const ExternalFailure(ExternalFailureKind.noModel);
      _post();
      return;
    }
    if (_queue.any((j) => j.identity == job.identity)) return;
    _queue.insert(0, job);
    final current = _current;
    if (current != null &&
        current.libraryRun &&
        !(_cancellation?.isCancelled ?? true)) {
      _resumeMarker = current.resume(_after, done, handled: _handled);
      _queue.insert(1, _resumeMarker!);
      _cancellation!.cancel();
    }
    _pump();
  }

  void retagAll({required String model, bool replaceOld = false}) {
    if (_closed) return;
    if (_model(model) == null) {
      lastError = const ExternalFailure(ExternalFailureKind.noModel);
      _post();
      return;
    }
    _queue.removeWhere((j) => j.libraryRun);
    _queue.insert(
      0,
      TaggingJob(model: model, scope: TaggingScope.all, replaceOld: replaceOld),
    );
    if (_current?.libraryRun ?? false) _cancellation?.cancel();
    _pump();
  }

  void pause() {
    if (_closed || _paused) return;
    _paused = true;
    final current = _current;
    // whatever runs goes on from where it got: selected media as much as a whole-library run
    if (current != null && !(_cancellation?.isCancelled ?? true)) {
      _resumeMarker = current.resume(_after, done, handled: _handled);
      _queue.insert(0, _resumeMarker!);
    }
    _cancellation?.cancel();
    _post();
  }

  void resume() {
    if (_closed) return;
    _paused = false;
    _pump();
    _post();
  }

  void cancel() {
    _queue.clear();
    _paused = false;
    _pausedForBackground = false;
    _cancellation?.cancel();
    _post();
  }

  /// 停止标记: what runs and what waits are given up, and automatic tagging rests.
  void stop() {
    _stopped = true;
    cancel();
  }

  void _pump() {
    if (_closed || _paused || running || _queue.isEmpty) return;
    final job = _queue.removeAt(0);
    _current = job;
    _after = job.resumeAfter;
    done = job.scope == TaggingScope.all ? job.doneBefore : 0;
    total = 0;
    _handled = 0;
    final cancellation = AiCancellation();
    _cancellation = cancellation;
    outcome = 'running';
    lastError = null;
    // Schedule after assignment so synchronous progress listeners see running.
    _task = Future<void>(() => _run(job, cancellation))
        .catchError((Object error, StackTrace stack) {
          lastError = unexpectedFailure(error, stack);
        })
        .whenComplete(() {
          final marker = _resumeMarker;
          if (marker != null) {
            final index = _queue.indexOf(marker);
            if (index >= 0) _queue[index] = job.resume(_after, done, handled: _handled);
            _resumeMarker = null;
          }
          outcome = cancellation.isCancelled
              ? 'cancelled'
              : lastError != null
              ? done > 0
                    ? 'partial'
                    : 'failed'
              : 'succeeded';
          _task = null;
          _current = null;
          _cancellation = null;
          currentPath = null;
          _post();
          _pump();
        });
    _post();
  }

  Future<void> _run(TaggingJob job, AiCancellation cancellation) async {
    final epoch = await core.epoch();
    final model = _model(job.model);
    if (model == null) {
      lastError = const ExternalFailure(ExternalFailureKind.noModel);
      return;
    }
    final counts = await core.counts();
    done = job.scope == TaggingScope.all ? job.doneBefore : 0;
    total = switch (job.scope) {
      TaggingScope.untagged => counts.total - counts.done,
      TaggingScope.media => job.media.length,
      TaggingScope.all => counts.total > done ? counts.total : done,
    };
    final titleKey = switch (job.scope) {
      TaggingScope.untagged => 'ai.activity.new',
      TaggingScope.media => 'ai.activity.retag',
      TaggingScope.all => 'ai.activity.retagAll',
    };
    title = L(titleKey, [model.title]);
    _post();
    final runStart = _now().millisecondsSinceEpoch ~/ 1000 - 1;
    // the grid shows the tags as they come: after each picture, at most once a second (a slow
    // on-device model takes seconds a picture), and at least every 12 (a fast service)
    var shown = _now();
    var first = true,
        after = job.resumeAfter,
        sinceVocabulary = 10,
        changed = 0;
    var vocabulary = <String>[];
    var failed = <String>[];
    final counted = job.scope == TaggingScope.untagged;
    // a re-tag has no record of what failed: the run says so at its end, not "succeeded"
    ExternalFailure? skipped;
    try {
      while (!cancellation.isCancelled) {
        final batch = switch (job.scope) {
          TaggingScope.untagged => await core.pending(job.model, runStart, 8),
          TaggingScope.media => first ? job.media : <MediaRef>[],
          TaggingScope.all => await core.page(after, 16),
        };
        first = false;
        if (batch.isEmpty) break;
        after = batch.last.media_id;
        if (counted) {
          final c = await core.counts();
          final skipped = await core.failures();
          total = done + (c.total - c.done - skipped).clamp(0, 9007199254740991);
          _post();
        }
        for (final media in batch) {
          if (cancellation.isCancelled) break;
          currentPath = media.path;
          currentKind = media.kind;
          _post();
          if (sinceVocabulary >= 10) {
            vocabulary = (await core.vocabulary()).take(150).toList();
            sinceVocabulary = 0;
          }
          sinceVocabulary++;
          final existing = await core.existing(media.media_id);
          if (cancellation.isCancelled) break;
          if (counted) {
            await core.attempt(AiAttemptStep.begin, media.media_id, job.model);
          }
          List<String> labels = [];
          ExternalFailure? failure;
          var unreadable = false;
          try {
            final picture = await _image(media);
            cancellation.check();
            if (picture == null) {
              failure = const ExternalFailure(ExternalFailureKind.unreadable);
            } else {
              labels = await _infer(
                model,
                picture,
                existing,
                vocabulary,
                media.text,
                cancellation,
              );
            }
          } on ExternalFailure catch (error) {
            if (error.kind == ExternalFailureKind.cancelled) {
              if (counted) {
                await core.attempt(
                  AiAttemptStep.undo,
                  media.media_id,
                  job.model,
                );
              }
              return;
            }
            failure = error;
          } catch (error, stack) {
            failure = unexpectedFailure(error, stack);
          }
          if (cancellation.isCancelled) {
            if (counted) {
              await core.attempt(AiAttemptStep.undo, media.media_id, job.model);
            }
            return;
          }
          unreadable = failure?.kind == ExternalFailureKind.unreadable;
          if (failure != null) {
            _handled++;
            if (!counted) skipped = failure;
            if (counted) {
              await core.attempt(
                AiAttemptStep.failed,
                media.media_id,
                job.model,
                reason: failure.message,
              );
            }
            if (!unreadable) {
              failed.add(media.media_id);
              if (failed.length >= 3) {
                if (counted) {
                  final giveBack = failed
                      .where((id) => !_givenBack.contains(id))
                      .toList();
                  _givenBack.addAll(giveBack);
                  for (final id in giveBack) {
                    await core.attempt(AiAttemptStep.undo, id, job.model);
                  }
                }
                lastError = failure;
                _post();
                return;
              }
            }
            if (job.scope == TaggingScope.all) _after = media.media_id;
            _post();
            continue;
          }
          failed = [];
          if (cancellation.isCancelled) {
            if (counted) {
              await core.attempt(AiAttemptStep.undo, media.media_id, job.model);
            }
            return;
          }
          try {
            await core.apply(
              media.media_id,
              job.model,
              labels,
              job.replaceOld && labels.isNotEmpty,
              epoch,
            );
          } catch (error, stack) {
            if (counted) {
              await core.attempt(AiAttemptStep.undo, media.media_id, job.model);
            }
            lastError = unexpectedFailure(error, stack);
            _post();
            return;
          }
          done++;
          changed++;
          _handled++;
          if (job.scope == TaggingScope.all) _after = media.media_id;
          _post();
          if (changed >= 12 || _now().difference(shown) >= const Duration(seconds: 1)) {
            changed = 0;
            shown = _now();
            if (!_closed) onChanged?.call();
          }
        }
      }
      if (skipped != null && !cancellation.isCancelled) lastError = skipped;
    } finally {
      if (!_closed && changed > 0) onChanged?.call();
    }
  }

  /// Before 清除所有数据: nothing queued, and the current work over.
  Future<void> stopForWipe() async {
    _paused = false;
    cancel();
    await settled;
  }

  Future<void> close() async {
    if (_closed) return;
    _lifecycle?.dispose();
    cancel();
    _closed = true;
    await settled;
  }

  @override
  void dispose() {
    if (!_closed) {
      cancel();
      _closed = true;
    }
    super.dispose();
  }
}
