import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
    // the web build plays the server's file by its address (ranges let it seek)
    await player.open(Media(OS.isWeb ? Uri.base.resolve(fileUrl(path)).toString() : File(path).absolute.uri.toString()), play: false);
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

/// Widget-free playback/policy controller. Use the re-exported VideoSurface
/// with surfaceController and NoVideoControls; the owner supplies localized UI.
class VideoPlayback {
  VideoPlayback({
    VideoEngine? engine,
    HeadphoneRoutes? routes,
    String? Function(String)? readSetting,
  }) : _engine = engine ?? MediaKitVideoEngine(),
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

  Future<void> _applyAudio() {
    final next = _audioTail.then((_) async {
      if (_closed) return;
      try {
        // not offered on Windows and Linux: a value set earlier must not keep them muted
        _headphonesOnly = !OS.isWindows && !OS.isLinux && headphonesOnlySetting(
          _readSetting('audio.headphonesOnly'),
        );
      } catch (_) {
        _headphonesOnly = true;
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
/// Where the system has a video decoder the app can call (iOS, iPadOS, macOS: AVFoundation;
/// Android: MediaMetadataRetriever) one frame is decoded there, in parallel, at the size the
/// largest poster needs, and every size is written at once. Elsewhere (Windows, Linux) a hidden
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
    OS.isWeb ? serverPoster(item.path, longSide, whole: true) : _posters.whole(item, longSide, cacheDir);
Future<String?> videoPoster(FeedItem item, int side, String cacheDir, {List<int> together = const []}) =>
    OS.isWeb ? serverPoster(item.path, side, whole: false) : _posters.poster(item, side, cacheDir, together: together);
