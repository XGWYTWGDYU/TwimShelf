import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as image;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';

import '../l10n/l10n.dart';
import 'audio_routes.dart';
import 'system_random.dart';
import '../app/prefs.dart';
import 'os.dart';
import 'files.dart';

export 'package:media_kit_video/media_kit_video.dart'
    show Video, VideoController, NoVideoControls;

export 'audio_routes.dart' show HeadphoneRoutes;

typedef VideoSurface = Video;

abstract interface class VideoEngine {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Duration get currentPosition;
  Duration get currentDuration;
  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> volume(double percent);
  /// Playback speed (1 normal; the player's long press holds 2.5).
  Future<void> rate(double rate);
  Future<void> loop(bool enabled);
  Future<bool> hasAudio();
  Future<Uint8List?> screenshot();
  /// Unloads the media and keeps the player for the next one: much cheaper than [dispose], which
  /// waits for the player's own thread to end (half a second and more, on the calling thread).
  Future<void> stop();
  Future<void> dispose();
}

class MediaKitVideoEngine implements VideoEngine {
  MediaKitVideoEngine() {
    MediaKit.ensureInitialized();
    player = Player(
      configuration: PlayerConfiguration(
        title: L('sidebar.library'),
        muted: true,
        logLevel: MPVLogLevel.error,
        protocolWhitelist: const ['file', 'data'],
      ),
    );
  }
  late final Player player;
  late final VideoController controller = _createController();
  VideoController _createController() {
    final result = VideoController(player);
    SchedulerBinding.instance.scheduleFrame();
    return result;
  }

  @override
  Stream<Duration> get position => player.stream.position;
  @override
  Stream<Duration> get duration => player.stream.duration;
  @override
  Duration get currentPosition => player.state.position;
  @override
  Duration get currentDuration => player.state.duration;
  @override
  Future<void> open(String path) async {
    await controller.platform.future.timeout(const Duration(seconds: 10));
    await player.open(Media(File(path).absolute.uri.toString()), play: false);
    if (player.state.duration == Duration.zero) {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10));
    }
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration value) => player.seek(value);
  @override
  Future<void> volume(double value) => player.setVolume(value);

  @override
  Future<void> rate(double value) => player.setRate(value);
  @override
  Future<void> loop(bool enabled) =>
      player.setPlaylistMode(enabled ? PlaylistMode.single : PlaylistMode.none);
  @override
  Future<bool> hasAudio() async =>
      player.state.tracks.audio.any((t) => t.id != 'auto' && t.id != 'no');
  @override
  Future<Uint8List?> screenshot() => player.screenshot(format: 'image/png');
  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> dispose() => player.dispose();
}

bool headphonesOnlySetting(String? value) {
  if (value == null) return false;
  return !const {
    'false',
    '0',
    'off',
    'no',
    '',
  }.contains(value.trim().toLowerCase());
}

/// Backwards-compatible facade over [VideoSession] for callers that query or seed resume state.
abstract final class VideoResume {
  static void leave(String path, Duration at, {bool quiet = false}) =>
      VideoSession.of(path).savePosition(at, quiet: quiet);

  static void leaveFrame(String path, Uint8List? frame) =>
      VideoSession.of(path).saveFrame(frame);

  static Uint8List? takeFrame(String path) => VideoSession.of(path).lastFrame;

  static Uint8List? peekFrame(String path) => VideoSession.of(path).lastFrame;

  static Future<Uint8List?> frameOf(VideoPlayback v) async {
    try {
      return await v.surfaceController.player
          .screenshot(format: 'image/jpeg')
          .timeout(const Duration(milliseconds: 220));
    } catch (_) {
      return null;
    }
  }

  static Duration? take(String path, String who) {
    final s = VideoSession.of(path);
    final at = s.position > Duration.zero ? s.position : null;
    if (at != null) {
      debugPrint('TwimShelf video: $who starts at ${(at.inMilliseconds / 1000).toStringAsFixed(2)} s');
    }
    return at;
  }
}

/// One shared video object for both the inline preview card (浏览) and the expanded full-screen
/// viewer ([VideoPage]):
/// * when a playing card is tapped to expand into the viewer, the viewer uses this same
///   [VideoSession] and its already-open [VideoPlayback] without reopening or seeking;
/// * when the viewer closes back to the card, this same [VideoSession] stays playing on the card;
/// * when a card scrolls out of view, [position] and [lastFrame] stay on this [VideoSession] while
///   its decoder returns to the idle pool, so the card freezes at that exact moment and resumes
///   from [position] when scrolled back into view.
class VideoSession extends ChangeNotifier {
  VideoSession._(this.path);

  final String path;

  static final _sessions = <String, VideoSession>{};
  static final _frameLru = <String>{};
  static const _maxCachedFrames = 48;
  static final _idle = <VideoPlayback>[];
  static bool _viewerOpen = false;
  static String? _viewerOpeningPath;

  static bool get isViewerOpen => _viewerOpen;

  /// Returns the shared [VideoSession] for [path].
  static VideoSession of(String path) =>
      _sessions.putIfAbsent(path, () => VideoSession._(path));

  /// Returns the shared [VideoSession] for [item] and warms its poster in [cacheDir].
  static VideoSession forItem(FeedItem item, {String? cacheDir}) {
    final s = of(item.path);
    if (cacheDir != null) s._ensurePoster(item, cacheDir);
    return s;
  }

  /// Players alive (currently playing across sessions, and kept idle in the pool).
  static ({int playing, int idle}) get debugPlayers => (
        playing: _sessions.values.where((s) => s._playback != null).length,
        idle: _idle.length,
      );

  /// Called before pushing the full-screen viewer for [openingPath]: keeps [openingPath]'s player
  /// alive and running for the viewer to adopt on frame 0, while stopping other inline cards
  /// in the background so the route transition begins without delay.
  static Future<void> beginViewer({String? openingPath}) async {
    _viewerOpen = true;
    _viewerOpeningPath = openingPath;
    for (final s in _sessions.values.toList()) {
      if (s._playback != null && s.path != openingPath && s._viewerOwners.isEmpty) {
        unawaited(s._stopPlayback(captureFrame: true));
      }
    }
  }

  /// Called as soon as the viewer starts closing so the active session knows its card can retain
  /// playback when the viewer page unmounts.
  static void willCloseViewer() {
    _viewerOpen = false;
    _viewerOpeningPath = null;
  }

  /// Called when the full-screen viewer finishes closing: resumes any visible inline cards.
  static void endViewer() {
    _viewerOpen = false;
    _viewerOpeningPath = null;
    for (final s in _sessions.values.toList()) {
      s._sync(notify: true);
    }
  }

  VideoPlayback? _playback;
  VideoPlayback? get playback => _playback;

  /// Decoded aspect ratio (width / height) of the active video player, if known.
  double? get aspectRatio {
    final p = _playback?.surfaceController.player;
    final w = p?.state.width ?? 0, h = p?.state.height ?? 0;
    return w > 0 && h > 0 ? w / h : null;
  }

  Duration _position = Duration.zero;
  Duration get position => _playback != null && _playback!.currentPosition > Duration.zero
      ? _playback!.currentPosition
      : _position;

  Uint8List? _lastFrame;
  Uint8List? get lastFrame => _lastFrame;

  String? _posterPath;
  String? get posterPath => _posterPath;
  bool _loadingPoster = false;

  bool _firstFrameReady = false;
  bool get firstFrameReady => _firstFrameReady;

  Object? _error;
  Object? get error => _error;

  final Set<Object> _cardOwners = {};
  final Set<Object> _viewerOwners = {};
  StreamSubscription<Duration>? _posSub;
  Future<VideoPlayback?>? _openingFuture;

  bool get inViewer => _viewerOwners.isNotEmpty;
  bool get hasVisibleCard => _cardOwners.isNotEmpty;

  void savePosition(Duration at, {bool quiet = false}) {
    if (at <= Duration.zero) return;
    _position = at;
    if (!quiet) {
      debugPrint('TwimShelf video: left ${path.split('/').last} at ${(at.inMilliseconds / 1000).toStringAsFixed(2)} s');
    }
  }

  void saveFrame(Uint8List? frame) {
    if (frame == null || frame.isEmpty) return;
    _lastFrame = frame;
    _frameLru.remove(path);
    _frameLru.add(path);
    while (_frameLru.length > _maxCachedFrames) {
      final oldest = _frameLru.first;
      _frameLru.remove(oldest);
      if (oldest != path) _sessions[oldest]?._clearFrame();
    }
    notifyListeners();
  }

  void _clearFrame() {
    if (_lastFrame != null) {
      _lastFrame = null;
      notifyListeners();
    }
  }

  Future<void> _ensurePoster(FeedItem item, String cacheDir) async {
    if (_posterPath != null || _loadingPoster) return;
    _loadingPoster = true;
    try {
      final p = await videoCardPoster(item, 1024, cacheDir);
      if (p != null && _posterPath == null) {
        _posterPath = p;
        notifyListeners();
      }
    } finally {
      _loadingPoster = false;
    }
  }

  void attachCard(Object owner, {FeedItem? item, String? cacheDir}) {
    if (item != null && cacheDir != null) _ensurePoster(item, cacheDir);
    if (_cardOwners.add(owner)) _sync();
  }

  void detachCard(Object owner) {
    if (_cardOwners.remove(owner)) _sync();
  }

  Future<VideoPlayback?> attachViewer(Object owner) {
    _viewerOwners.add(owner);
    if (_viewerOpeningPath == path) _viewerOpeningPath = null;
    return _sync();
  }

  /// Mutes and resets playback speed as the viewer starts its close animation, while keeping the
  /// video playing live inside the shrinking transition rect.
  void prepareLeaveViewer() {
    _viewerOpen = false;
    _viewerOpeningPath = null;
    final v = _playback;
    if (v == null) return;
    if (v.currentPosition > Duration.zero) _position = v.currentPosition;
    unawaited(v.returnToCard().catchError((Object _) {}));
  }

  void detachViewer(Object owner) {
    if (_viewerOwners.remove(owner)) {
      // Called from VideoPageState.dispose() during finalizeTree: defer any state notifications
      // to a microtask so we never notify widgets while the tree is locked, while keeping an
      // inline card's playback running without interruption.
      final keepOnCard = !_viewerOpen && _cardOwners.isNotEmpty;
      if (keepOnCard && _playback != null) {
        unawaited(_playback!.returnToCard().catchError((Object _) {}));
        return;
      }
      scheduleMicrotask(() => _sync(notify: true));
    }
  }

  Future<VideoPlayback?> _sync({bool notify = true}) {
    final wantViewer = _viewerOwners.isNotEmpty;
    final wantCard = !_viewerOpen && _cardOwners.isNotEmpty;
    final heldForOpeningViewer = _viewerOpen && _viewerOpeningPath == path;
    final wantPlay = wantViewer || wantCard || heldForOpeningViewer;

    if (!wantPlay) {
      if (_playback != null) {
        unawaited(_stopPlayback(captureFrame: _firstFrameReady));
      }
      return Future.value(null);
    }

    final existing = _playback;
    if (existing != null) {
      if (_openingFuture != null) return _openingFuture!;
      if (wantViewer) {
        unawaited(existing.enterViewer().catchError((Object _) {}));
      } else if (wantCard) {
        unawaited(existing.returnToCard().catchError((Object _) {}));
      }
      return Future.value(existing);
    }

    return _openingFuture ??= _startPlayback().whenComplete(() {
      _openingFuture = null;
    });
  }

  Future<VideoPlayback?> _startPlayback() async {
    VideoPlayback? v;
    _error = null;
    _firstFrameReady = false;

    try {
      await Future<void>.value();
      v = _idle.isNotEmpty ? _idle.removeLast() : VideoPlayback();
      _playback = v;
      notifyListeners();

      final resumeFrom = _position > Duration.zero ? _position : null;
      var seekDone = resumeFrom == null;
      // The first frame worth showing is this video's own, after the seek: a reused player still
      // holds the last video's last frame, and the file opens on its frame 0 (at the last video's
      // size) before the seek lands. Played past the place it resumes at (or looped round to the
      // start, when that place was near the end), it is there.
      final shownFrom = (resumeFrom ?? Duration.zero) + const Duration(milliseconds: 30);
      bool settled(Duration p) => p > shownFrom || (resumeFrom != null && p + const Duration(milliseconds: 500) < resumeFrom);

      _posSub?.cancel();
      _posSub = v.position.listen((p) {
        if (_playback != v) return;
        if (seekDone && p > Duration.zero) {
          _position = p;
          if (!_firstFrameReady && settled(p)) {
            final st = v!.surfaceController.player.state;
            if ((st.width ?? 0) > 0 && (st.height ?? 0) > 0) {
              _firstFrameReady = true;
              _lastFrame = null;
              notifyListeners();
            }
          }
        }
      });

      final forViewer = _viewerOwners.isNotEmpty;
      if (!forViewer) await v.setMuted(true);
      await v.setLoop(true);
      await v.open(path, autoplay: false);
      if (_playback != v) return null;

      if (resumeFrom != null) {
        await v.seek(resumeFrom);
        if (_playback != v) return null;
      }
      seekDone = true;

      if (_viewerOwners.isNotEmpty) {
        await v.enterViewer();
      } else {
        await v.returnToCard();
      }

      if (_playback != v) return null;
      final stillWanted = _viewerOwners.isNotEmpty ||
          (!_viewerOpen && _cardOwners.isNotEmpty) ||
          (_viewerOpen && _viewerOpeningPath == path);
      if (!stillWanted) {
        await _stopPlayback(captureFrame: _firstFrameReady);
        return null;
      }
      return v;
    } catch (e) {
      _error = e;
      if (v != null && _playback == v) {
        await _stopPlayback(captureFrame: false);
      } else {
        _playback = null;
        notifyListeners();
      }
      return null;
    }
  }

  Future<void> _stopPlayback({required bool captureFrame}) async {
    final v = _playback;
    if (v == null) return;
    _posSub?.cancel();
    _posSub = null;
    _playback = null;
    _firstFrameReady = false;

    final pos = v.currentPosition;
    if (pos > Duration.zero) {
      savePosition(pos);
    }
    notifyListeners();

    _idle.add(v);
    await v.release(
      onBeforeStop: captureFrame
          ? () async {
              final frame = await VideoResume.frameOf(v);
              if (frame != null && _playback == null) {
                saveFrame(frame);
              }
            }
          : null,
    ).catchError((Object _) {});
  }
}

/// Shared visual surface for a [VideoSession], used by both the inline card preview in 浏览 and
/// the expanded full-screen [VideoPage] in the viewer.
class VideoSessionView extends StatelessWidget {
  const VideoSessionView({
    super.key,
    required this.session,
    this.fill = Colors.transparent,
    this.showPlayBadgeWhenStopped = true,
    this.fallback,
  });

  final VideoSession session;
  final Color fill;
  final bool showPlayBadgeWhenStopped;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final v = session.playback;
        final frame = session.lastFrame;
        final poster = session.posterPath;
        return Stack(fit: StackFit.expand, children: [
          if (fill != Colors.transparent) ColoredBox(color: fill),
          if (v == null || !session.firstFrameReady)
            frame != null
                ? IgnorePointer(child: Image.memory(frame, fit: BoxFit.contain, gaplessPlayback: true))
                : poster != null
                    ? IgnorePointer(child: Image(image: localFileImage(poster), fit: BoxFit.contain, gaplessPlayback: true))
                    : (fallback ?? const SizedBox.expand()),
          // mounted from the start (its texture takes the frames), shown from this video's first
          // frame after the seek: before it, a reused player shows the last video's last frame,
          // then this one's frame 0 at the wrong size (the frame or poster under it stays meanwhile)
          if (v != null)
            Opacity(
              opacity: session.firstFrameReady ? 1 : 0,
              child: VideoSurface(
                controller: v.surfaceController,
                controls: NoVideoControls,
                resumeUponEnteringForegroundMode: true,
                fill: Colors.transparent,
              ),
            ),
          if (showPlayBadgeWhenStopped && v == null && frame == null)
            const Center(child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 56)),
        ]);
      },
    );
  }
}

/// Widget-free playback/policy controller. Use the re-exported VideoSurface
/// with surfaceController and NoVideoControls; the owner supplies localized UI.
class VideoPlayback {
  VideoPlayback({
    VideoEngine? engine,
    HeadphoneRoutes? routes,
    String? Function(String)? readSetting,
    bool? headphonesPolicy,
  }) : _policy = headphonesPolicy ?? OS.isIOS,
       _engine = engine ?? MediaKitVideoEngine(),
       _routes = routes ?? SystemHeadphoneRoutes(),
       _readSetting = readSetting ?? ((_) => Prefs.instance.headphonesOnly ? '1' : '0') {
    _routeSubscription = _routes.changes.listen((connected) {
      if (_headphones && !connected) _allowSpeaker = false;
      _headphones = connected;
      // A disconnection mutes first, before any setting/database work.
      if (!connected && _headphonesOnly) {
        unawaited(_engine.volume(0).catchError((Object _) {}));
      }
      unawaited(_applyAudio().catchError((Object _) {}));
    });
  }
  /// "Sound only through headphones" applies here: on iPhone and iPad only (elsewhere a value
  /// set earlier, or synced from another device, must not keep videos muted).
  final bool _policy;
  final VideoEngine _engine;
  final HeadphoneRoutes _routes;
  final String? Function(String) _readSetting;
  late final StreamSubscription<bool> _routeSubscription;
  final muted = ValueNotifier<bool>(true);
  final needsSpeakerConsent = ValueNotifier<bool>(false);
  bool _manualMute = false,
      _allowSpeaker = false,
      _headphones = false,
      _headphonesOnly = false,
      _hasAudio = true,
      _closed = false,
      _opening = false;
  int _generation = 0;
  Future<void> _audioTail = Future.value();
  Stream<Duration> get position => _engine.position;
  Stream<Duration> get duration => _engine.duration;
  Duration get currentPosition => _engine.currentPosition;
  Duration get currentDuration => _engine.currentDuration;
  VideoController get surfaceController {
    if (_engine is! MediaKitVideoEngine) throw StateError('video.noSurface');
    return (_engine).controller;
  }

  void _check() {
    if (_closed) throw StateError('video.disposed');
  }

  Future<void> open(String path, {bool autoplay = true}) async {
    _check();
    await _released.catchError((Object _) {});
    if (!await fileExists(path)) {
      throw const FileSystemException('video.fileMissing');
    }
    final generation = ++_generation;
    _opening = true;
    _allowSpeaker = false;
    _hasAudio = true;
    needsSpeakerConsent.value = false;
    await _engine.volume(0);
    muted.value = true;
    try {
      await _engine.open(path);
      if (generation != _generation || _closed) return;
      _hasAudio = await _engine.hasAudio();
      _headphones = await _routes.current();
      if (generation != _generation || _closed) return;
      _opening = false;
      await _applyAudio();
      if (autoplay && generation == _generation && !_closed) {
        await _engine.play();
      }
    } finally {
      if (generation == _generation) _opening = false;
    }
  }

  /// Transitions an already-open playback into the full-screen viewer: applies the viewer's
  /// audio/headphones policy without reopening or seeking the file.
  Future<void> enterViewer() async {
    if (_closed) return;
    _manualMute = false;
    _allowSpeaker = false;
    _hasAudio = await _engine.hasAudio();
    _headphones = await _routes.current();
    await _applyAudio();
    if (!_closed) await _engine.play();
  }

  /// Transitions an already-open playback back to its inline feed card: muted, normal speed,
  /// looping, and playing.
  Future<void> returnToCard() async {
    if (_closed) return;
    _manualMute = true;
    _allowSpeaker = false;
    needsSpeakerConsent.value = false;
    muted.value = true;
    await _engine.volume(0);
    await _engine.rate(1.0);
    await _engine.loop(true);
    if (!_closed) await _engine.play();
  }

  Future<void> _applyAudio() {
    final next = _audioTail.then((_) async {
      if (_closed) return;
      try {
        _headphonesOnly = _policy && headphonesOnlySetting(_readSetting('audio.headphonesOnly'));
      } catch (_) {
        _headphonesOnly = _policy;
      }
      final blocked = _headphonesOnly && !_headphones && !_allowSpeaker;
      final shouldMute = _opening || _manualMute || blocked;
      needsSpeakerConsent.value =
          !_opening && _hasAudio && blocked && !_manualMute;
      muted.value = shouldMute;
      await _engine.volume(shouldMute ? 0 : 100);
    });
    _audioTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Call after an audio setting changes. A speaker override lasts one video.
  Future<void> refreshAudioPolicy() async {
    _check();
    _headphones = await _routes.current();
    await _applyAudio();
  }

  Future<void> allowSpeakerForCurrentVideo([bool allow = true]) async {
    _check();
    _allowSpeaker = allow;
    await _applyAudio();
  }

  Future<void> setMuted(bool value) async {
    _check();
    _manualMute = value;
    await _applyAudio();
  }

  Future<void> play() async {
    _check();
    await refreshAudioPolicy();
    await _engine.play();
  }

  Future<void> pause() async {
    _check();
    await _engine.pause();
  }

  Future<void> seek(Duration value) async {
    _check();
    final maximum = _engine.currentDuration;
    final end = maximum > Duration.zero && value > maximum ? maximum : value;
    await _engine.seek(end < Duration.zero ? Duration.zero : end);
  }

  Future<void> setRate(double rate) async {
    _check();
    await _engine.rate(rate);
  }

  /// The player's own volume (0–100), within the audio policy (muting wins).
  Future<void> setVolume(double percent) async {
    _check();
    if (!muted.value) await _engine.volume(percent.clamp(0, 100));
  }

  Future<void> setLoop(bool enabled) async {
    _check();
    await _engine.loop(enabled);
  }

  /// Stops the video and keeps the player for another one ([open] again); a reused player
  /// starts muted, as a new one does. [open] waits for a release still under way.
  Future<void> release({Future<void> Function()? onBeforeStop}) {
    if (_closed) return Future.value();
    _generation++;
    _opening = false;
    muted.value = true;
    needsSpeakerConsent.value = false;
    return _released = () async {
      await _engine.pause();
      if (onBeforeStop != null) {
        try {
          await onBeforeStop();
        } catch (_) {}
      }
      await _engine.stop();
      await _engine.volume(0);
      await _engine.rate(1.0);
    }();
  }
  Future<void> _released = Future.value();

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    await _routeSubscription.cancel();
    await _routes.dispose();
    await _audioTail;
    await _engine.dispose();
    muted.dispose();
    needsSpeakerConsent.dispose();
  }
}

typedef PosterFrameGrabber = Future<Uint8List?> Function(
  String path,
  Duration at,
);

/// Square poster frames for video tiles, cached on disk like photo thumbnails.
///
/// Where the system has a video decoder the app can call (iOS, iPadOS: AVFoundation;
/// Android: MediaMetadataRetriever) one frame is decoded there, in parallel, at the size the
/// largest poster needs, and every size is written at once. Elsewhere a hidden
/// media_kit player grabs the frame, one at a time, and the crop happens off the UI isolate.
/// A cache hit only reads the JPEG's header to check its size.
class VideoPosters {
  VideoPosters({PosterFrameGrabber? grabFrame, bool? native})
    : _grabFrame = grabFrame ?? _nativeFrame,
      _native = native ?? (grabFrame == null && TlNative.hasPosters);
  final PosterFrameGrabber _grabFrame;
  final bool _native;
  final _pending = <String, Future<String?>>{};

  /// The poster at [side]; [together] are the other sizes the caller will want (the grid's
  /// small and large tiles), made from the same decoded frame.
  Future<String?> poster(FeedItem item, int side, String cacheDir, {List<int> together = const []}) {
    if (item.kind != MediaKind.video ||
        side < 1 ||
        side > 8192 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(item.media_id)) {
      return Future.value();
    }
    final key = _path(cacheDir, side, item.media_id);
    return _pending[key] ??= _make(item, side, cacheDir, together).whenComplete(() {
      _pending.remove(key);
    });
  }

  /// One frame in the video's own shape, its long side at most [longSide]: a card of 浏览 shows it
  /// until the video plays (the posters above are the grid's squares).
  Future<String?> whole(FeedItem item, int longSide, String cacheDir) {
    if (item.kind != MediaKind.video || longSide < 1 || longSide > 8192 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(item.media_id)) {
      return Future.value();
    }
    final key = _path(cacheDir, 'whole$longSide', item.media_id);
    return _pending[key] ??= _makeWhole(item, longSide, cacheDir).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<String?> _makeWhole(FeedItem item, int longSide, String cacheDir) async {
    final destination = _path(cacheDir, 'whole$longSide', item.media_id);
    try {
      final source = await File(item.path).stat();
      if (source.type != FileSystemEntityType.file) return null;
      final cached = File(destination);
      if (await cached.exists() && !(await cached.lastModified()).isBefore(source.modified)) return destination;
      if (_native) {
        final ok = await TlNative.posterFrame(item.path, sides: [longSide], whole: true, out: _path(cacheDir, 'whole{side}', item.media_id));
        return ok ? destination : null;
      }
      final bytes = await _grabFrame(item.path, const Duration(milliseconds: 500));
      if (bytes == null) return null;
      final jpeg = await _wholeJpegOff(bytes, longSide);
      if (jpeg == null) return null;
      await cached.parent.create(recursive: true);
      final temporary = File('$destination.${DateTime.now().microsecondsSinceEpoch}.partial');
      try {
        await temporary.writeAsBytes(jpeg, flush: true);
        await temporary.rename(destination);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return destination;
    } catch (_) {
      return null;
    }
  }

  static String _path(String cacheDir, Object side, String id) => File('$cacheDir/$side/$id.jpg').absolute.path;

  Future<String?> _make(FeedItem item, int side, String cacheDir, List<int> together) async {
    final destination = _path(cacheDir, side, item.media_id);
    try {
      final source = await File(item.path).stat();
      if (source.type != FileSystemEntityType.file) return null;
      Future<bool> fresh(int s) async {
        final f = File(_path(cacheDir, s, item.media_id));
        return await f.exists() && !(await f.lastModified()).isBefore(source.modified) && jpegSide(f) == s;
      }

      if (await fresh(side)) return destination;
      if (_native) {
        // every size missing from the cache, from one decode
        final sides = {side, for (final s in together) if (s >= 1 && s <= 8192 && !await fresh(s)) s}.toList();
        final ok = await TlNative.posterFrame(item.path, sides: sides, out: _path(cacheDir, '{side}', item.media_id));
        if (!ok) return null;
        final after = await File(item.path).stat();
        return after.modified == source.modified && after.size == source.size ? destination : null;
      }
      final bytes = await _grabFrame(
        item.path,
        const Duration(milliseconds: 500),
      );
      if (bytes == null) return null;
      final jpeg = await _squareJpegOff(bytes, side);
      if (jpeg == null) return null;
      final after = await File(item.path).stat();
      if (after.modified != source.modified || after.size != source.size) {
        return null;
      }
      final target = File(destination);
      await target.parent.create(recursive: true);
      final temporary = File(
        '$destination.${DateTime.now().microsecondsSinceEpoch}.${const SystemRandom().nextInt(0x100000000)}.partial',
      );
      await temporary.create(exclusive: true);
      try {
        await temporary.writeAsBytes(jpeg, flush: true);
        await temporary.rename(destination);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return destination;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _nativeTail = Future.value();
  static Future<Uint8List?> _nativeFrame(String path, Duration at) {
    final result = _nativeTail.then((_) => _grabNative(path, at));
    _nativeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Future<Uint8List?> _grabNative(String path, Duration at) async {
    final engine = MediaKitVideoEngine();
    try {
      await engine.volume(0);
      await engine.open(path);
      final length = engine.currentDuration;
      final target = length > Duration.zero && at >= length
          ? Duration(microseconds: max(0, length.inMicroseconds - 1000))
          : at;
      await engine.seek(target);
      // JPEG, not PNG: a full-size PNG costs more to encode here and to decode below
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final bytes = await engine.player.screenshot(format: 'image/jpeg');
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
      return null;
    } finally {
      await engine.dispose();
    }
  }
}

/// The side of a square baseline/progressive JPEG from its SOF header (reads only the start of
/// the file), or null when it is not a JPEG or not square.
int? jpegSide(File f) {
  RandomAccessFile? r;
  try {
    r = f.openSync();
    final head = r.readSync(64 * 1024);
    if (head.length < 4 || head[0] != 0xff || head[1] != 0xd8) return null;
    var i = 2;
    while (i + 9 < head.length) {
      if (head[i] != 0xff) return null;
      final marker = head[i + 1];
      final length = head[i + 2] << 8 | head[i + 3];
      // SOF0–SOF15 except DHT (C4), JPG (C8) and DAC (CC)
      if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
        final h = head[i + 5] << 8 | head[i + 6], w = head[i + 7] << 8 | head[i + 8];
        return w == h ? w : null;
      }
      i += 2 + length;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    r?.closeSync();
  }
}

/// At the top level: a closure inside a method would carry that method's scope to the isolate.
Future<Uint8List?> _squareJpegOff(Uint8List bytes, int side) => coreRunAsync(() => _squareJpeg(bytes, side));

Future<Uint8List?> _wholeJpegOff(Uint8List bytes, int longSide) => coreRunAsync(() => _wholeJpeg(bytes, longSide));

Uint8List? _wholeJpeg(Uint8List bytes, int longSide) {
  final decoded = image.decodeImage(bytes);
  if (decoded == null) return null;
  final oriented = image.bakeOrientation(decoded);
  final wide = oriented.width >= oriented.height;
  final fits = (wide ? oriented.width : oriented.height) <= longSide;
  final sized = fits ? oriented : image.copyResize(oriented, width: wide ? longSide : null, height: wide ? null : longSide, interpolation: image.Interpolation.cubic);
  return image.encodeJpg(sized, quality: 85);
}

Uint8List? _squareJpeg(Uint8List bytes, int side) {
  final decoded = image.decodeImage(bytes);
  if (decoded == null) return null;
  final oriented = image.bakeOrientation(decoded);
  final square = image.copyResizeCropSquare(
    oriented,
    size: side,
    interpolation: image.Interpolation.cubic,
  );
  final rgb = image.Image(width: side, height: side, numChannels: 3);
  image.fill(rgb, color: image.ColorRgb8(255, 255, 255));
  image.compositeImage(rgb, square);
  return image.encodeJpg(rgb, quality: 85);
}

final _posters = VideoPosters();
Future<String?> videoCardPoster(FeedItem item, int longSide, String cacheDir) =>
    _posters.whole(item, longSide, cacheDir);
Future<String?> videoPoster(FeedItem item, int side, String cacheDir, {List<int> together = const []}) =>
    _posters.poster(item, side, cacheDir, together: together);
