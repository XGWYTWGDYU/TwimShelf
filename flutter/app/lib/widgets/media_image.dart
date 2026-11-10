import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:tl_core/tl_core.dart';
import '../platform/files.dart';
import '../platform/os.dart';

/// Flutter's own decoder leaves HEIC and AVIF to the device, if it has one: these go through the
/// core's, on every platform.
bool isHeifPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return const {'heic', 'heif', 'hif', 'avif'}.contains(path.substring(dot + 1).toLowerCase());
}

/// A media file for an [Image], at most [maxSide] when it needs the core, decoded to [cacheWidth].
ImageProvider mediaImage(String path, {required int cacheWidth, required int maxSide}) => ResizeImage.resizeIfNeeded(
      cacheWidth,
      null,
      isHeifPath(path) ? HeifFileImage(path, maxSide) : localFileImage(path),
    );

class HeifFileImage extends ImageProvider<HeifFileImage> {
  const HeifFileImage(this.path, this.maxSide);
  final String path;
  final int maxSide;

  /// Where the JPEGs go: beside the thumbnails, cleared with them (set by ThumbStore).
  static String? cacheDir;

  @override
  Future<HeifFileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(HeifFileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: path);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final jpeg = await Core.displayImageAsync(path, maxSide, cacheDir ?? (OS.isWeb ? serverInfo.cache : Directory.systemTemp.path));
    return decode(await ui.ImmutableBuffer.fromUint8List(await readFileBytes(jpeg)));
  }

  @override
  bool operator ==(Object other) => other is HeifFileImage && other.path == path && other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(path, maxSide);
}
