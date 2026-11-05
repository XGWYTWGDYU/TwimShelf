import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../platform/video.dart';
import '../widgets/media_image.dart';

/// Square thumbnails of media for the grids, as the native `GridThumbnails` does it:
///
/// * two sizes only — a **small** one shared by every tile up to about the middle zoom level
///   (a scroll or a zoom never asks for a new one) and a **large** one only for tiles that get
///   big, drawn over the small one once ready;
/// * made (decoded, oriented, cropped, cached as JPEG on disk) by the Rust core in a few
///   background isolates, then decoded by the engine at the size needed;
/// * [image] answers at once with what is at hand — a frame never waits. What a frame lacks is
///   asked for in drawing order; asks the next frame no longer makes are dropped before they
///   start, so a fast scroll decodes what is on screen now rather than a backlog;
/// * a memory budget, least recently drawn first out.
class ThumbStore {
  ThumbStore._(this._cacheDir, this._workers);

  static Future<ThumbStore> create() async {
    final base = Platform.environment['TL_LIBRARY_DIR'] != null
        ? Directory('${Platform.environment['TL_LIBRARY_DIR']}${Platform.pathSeparator}.thumbs')
        : Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}GridThumbnails');
    await base.create(recursive: true);
    HeifFileImage.cacheDir = base.path;
    final n = math.max(2, math.min(4, Platform.numberOfProcessors - 2));
    final workers = await Future.wait([for (var i = 0; i < n; i++) _Worker.spawn()]);
    return ThumbStore._(base.path, workers);
  }

  final String _cacheDir;
  /// Where the thumbnails and video posters are cached (the feed's video cards share it).
  String get cacheDir => _cacheDir;
  final List<_Worker> _workers;

  /// Pixel sides of the two sizes.
  int smallSide = 384;
  int largeSide = 1280;

  /// Bytes of decoded images kept (RGBA).
  int budget = 192 << 20;
  int _bytes = 0;
  /// Counts drawn frames: what a frame drew is never evicted while it may still be on screen.
  int _frame = 0;
  final _entries = <String, _Entry>{};
  final Set<String> _failed = {};
  final Set<String> _videos = {};
  final Set<String> _running = {};
  final Set<_Worker> _active = {};
  final Map<String, FeedItem> _videoItems = {};
  final Set<String> _nearby = {};
  /// More known videos than this: those neither near the screen nor loaded are forgotten (they
  /// come back with the next frame that draws them).
  static const _maxVideoItems = 2048;
  bool _disposed = false;
  int _generation = 0;

  @visibleForTesting
  int loads = 0;
  @visibleForTesting
  int get decodedBytes => _bytes;
  @visibleForTesting
  bool hasImage(String id) => _entries[id]?.small != null;
  final List<(String, bool)> _wanted = [];
  final Set<String> _wantedKeys = {};

  /// A picture arrived: the grid draws again.
  VoidCallback? onLoaded;

  /// A media could not be decoded (the app marks it damaged).
  void Function(String mediaId)? onFailed;

  /// Sizes for a screen scale: the small one covers a middle-level tile (about 134 logical
  /// pixels at any window width), the large one the biggest tiles.
  void setScale(double scale) {
    final s = (((134 * scale) / 64).ceil() * 64).clamp(128, 512);
    if (s == smallSide) return;
    smallSide = s;
    largeSide = (s * 3.4 / 128).ceil() * 128;
    clear();
  }

  /// A new frame begins: what the last one lacked no longer counts.
  void beginFrame() {
    _frame++;
    _wanted.clear();
    _wantedKeys.clear();
    _nearby.clear();
  }

  bool isVideo(String id) => _videos.contains(id);
  bool isFailed(String id) => _failed.contains(id);

  /// The best image at hand for a tile [pixels] wide; asks for what is missing.
  ui.Image? image(String id, double pixels, {FeedItem? item}) {
    if (item?.kind == MediaKind.video) {
      _videos.add(id);
      _videoItems[id] = item!;
    }
    _nearby.add(id);
    final e = _entries.remove(id);
    if (e != null) {
      _entries[id] = e; // most recently used last
      e.drawnIn = _frame;
    }
    final wantsLarge = pixels > smallSide * 1.3;
    if (wantsLarge && e?.large != null) return e!.large;
    if (e?.small == null) _want(id, false);
    if (wantsLarge) _want(id, true);
    return e?.small ?? e?.large;
  }

  void _want(String id, bool large) {
    final key = '${large ? 'L' : 'S'}$id';
    if (_failed.contains(id) || (_videos.contains(id) && !_videoItems.containsKey(id)) || _running.contains(key) || !_wantedKeys.add(key)) return;
    _wanted.add((id, large));
  }

  /// Protect a viewport margin and queue its small thumbnails after visible tiles.
  void prefetch(FeedItem item) {
    final id = item.media_id;
    _nearby.add(id);
    if (item.kind == MediaKind.video) {
      _videos.add(id);
      _videoItems[id] = item;
    }
    if (_entries[id]?.small == null) _want(id, false);
  }

  /// Starts what the frame lacks, up to the free workers (call after drawing a frame).
  void endFrame() {
    if (_disposed) return;
    // pictures that have left the screen may go now
    _trim();
    if (_videoItems.length > _maxVideoItems) {
      _videoItems.removeWhere((id, _) => !_nearby.contains(id) && !_entries.containsKey(id));
      _videos.removeWhere((id) => !_videoItems.containsKey(id));
    }
    for (final w in _workers) {
      if (_active.contains(w) || _wanted.isEmpty) continue;
      final (id, large) = _wanted.removeAt(0);
      _start(w, id, large);
    }
  }

  Future<void> _start(_Worker w, String id, bool large) async {
    final key = '${large ? 'L' : 'S'}$id';
    _running.add(key);
    _active.add(w);
    final generation = _generation;
    loads++;
    final side = large ? largeSide : smallSide;
    try {
      final video = _videoItems[id];
      final r = video == null
          ? await w.run(id, side, _cacheDir)
          : await videoPoster(video, side, _cacheDir, together: [smallSide, largeSide]);
      if (_disposed || generation != _generation) return;
      if (r == 'video') {
        _videos.add(id);
      } else if (r == _Worker.notMade) {
        // says nothing of the media: no picture for now, and no mark on it
        _failed.add(id);
      } else if (r == null) {
        _failed.add(id);
        // a video poster depends on the device's decoders, and says nothing about the file
        if (video == null) onFailed?.call(id);
      } else {
        final bytes = await File(r).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: side, targetHeight: side);
        late final ui.FrameInfo frame;
        try {
          frame = await codec.getNextFrame();
        } finally {
          codec.dispose();
        }
        if (_disposed || generation != _generation) {
          frame.image.dispose();
          return;
        }
        final e = _entries.remove(id) ?? _Entry();
        final img = frame.image;
        final size = img.width * img.height * 4;
        // a replaced picture's bytes go before the new ones count (the total never drifts up)
        if (large) {
          if (e.large != null) _bytes -= e.largeBytes;
          e.large?.dispose();
          e.large = img;
          e.largeBytes = size;
        } else {
          if (e.small != null) _bytes -= e.smallBytes;
          e.small?.dispose();
          e.small = img;
          e.smallBytes = size;
        }
        e.drawnIn = _frame;
        _entries[id] = e;
        _bytes += size;
        _trim();
        onLoaded?.call();
      }
    } catch (_) {
      // the cache file could not be read or shown: nothing is known about the media itself
      if (!_disposed && generation == _generation) _failed.add(id);
    } finally {
      _active.remove(w);
      _running.remove(key);
      if (!_disposed && generation != _generation) onLoaded?.call();
      endFrame(); // the worker is free: go on with what the last frame lacked
    }
  }

  /// Least recently drawn first out, down to the budget — but never a picture drawn in this frame
  /// or the last (it is on screen: taking it would blank a tile and load it again, over and over).
  /// When what is on screen alone exceeds the budget, the cache stays over it for now.
  void _trim() {
    if (_bytes <= budget) return;
    // Large zoom detail is expendable before the small scroll-back image.
    for (final entry in _entries.entries) {
      if (_bytes <= budget) break;
      final e = entry.value;
      if (e.drawnIn >= _frame - 1 || _nearby.contains(entry.key)) continue;
      if (e.large != null) {
        _bytes -= e.largeBytes;
        e.large!.dispose();
        e.large = null;
        e.largeBytes = 0;
      }
    }
    final old = [for (final MapEntry(:key, :value) in _entries.entries) if (value.drawnIn < _frame - 1 && !_nearby.contains(key)) key];
    for (final k in old) {
      if (_bytes <= budget) break;
      final e = _entries.remove(k)!;
      _bytes -= (e.small != null ? e.smallBytes : 0) + (e.large != null ? e.largeBytes : 0);
      e.small?.dispose();
      e.large?.dispose();
    }
  }

  void clear() {
    _generation++;
    _wanted.clear();
    _wantedKeys.clear();
    _nearby.clear();
    _failed.clear();
    _videos.clear();
    _videoItems.clear();
    for (final e in _entries.values) {
      e.small?.dispose();
      e.large?.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  void dispose() {
    _disposed = true;
    onLoaded = null;
    onFailed = null;
    clear();
    for (final w in _workers) {
      w.close();
    }
  }
}

class _Entry {
  ui.Image? small;
  ui.Image? large;
  /// The decoded sizes (RGBA bytes) the budget counts.
  int smallBytes = 0, largeBytes = 0;
  /// The frame that last drew it.
  int drawnIn = 0;
}

/// A background isolate making thumbnails with the core, one at a time.
class _Worker {
  _Worker(this._send, this._port, this._replies);
  final SendPort _send;
  final ReceivePort _port;
  final Stream<dynamic> _replies;

  static Future<_Worker> spawn() async {
    final port = ReceivePort();
    await Isolate.spawn(_main, port.sendPort);
    final replies = port.asBroadcastStream();
    final send = await replies.first as SendPort;
    return _Worker(send, port, replies);
  }

  /// The answer when the thumbnail could not be made for another reason than the media (a cache
  /// folder that cannot be written, a full disk).
  static const notMade = 'not-made';

  /// The thumbnail's file path, 'video', [notMade], or null when the media cannot be decoded.
  Future<String?> run(String id, int side, String dir) async {
    final reply = _replies.first;
    _send.send((id, side, dir));
    return await reply as String?;
  }

  void close() {
    _send.send(null);
    _port.close();
  }

  static void _main(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    inbox.listen((msg) {
      if (msg == null) {
        inbox.close();
        return;
      }
      final (id, side, dir) = msg as (String, int, String);
      try {
        final r = Core.thumbnail(id, side, dir);
        out.send(switch (r) { ThumbnailImage(:final path) => path, ThumbnailVideo() => 'video' });
      } on ThumbnailNotDecodable {
        out.send(null);
      } catch (_) {
        out.send(notMade);
      }
    });
  }
}
