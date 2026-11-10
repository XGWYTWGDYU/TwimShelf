
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';
import '../platform/video.dart';
import '../platform/files.dart';

/// A media's square thumbnail outside the grids (folder covers, lists), made and cached by the
/// core; videos and media without a picture show an icon instead.
/// Off the UI isolate; a top-level function so the isolate gets only these values (a closure
/// made inside a widget's state would try to send the state along).
Future<ThumbnailResult> _thumbnail(String id, int side, String dir) => coreRunAsync(() => Core.thumbnail(id, side, dir));

class CoreThumbnail extends StatefulWidget {
  const CoreThumbnail({super.key, required this.mediaId, required this.cacheDir, this.size = 160, this.video = false, this.videoPath});
  final String mediaId;
  final String cacheDir;
  /// Logical side it is drawn at.
  final double size;
  final bool video;
  /// The file of a video, for its poster.
  final String? videoPath;

  @override
  State<CoreThumbnail> createState() => _CoreThumbnailState();
}

class _CoreThumbnailState extends State<CoreThumbnail> {
  String? _path;
  bool _none = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoreThumbnail old) {
    super.didUpdateWidget(old);
    if (old.mediaId != widget.mediaId) {
      _path = null;
      _none = false;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.mediaId, dir = widget.cacheDir;
    final side = (widget.size * 3).ceil().clamp(128, 768);
    try {
      final r = await _thumbnail(id, side, dir);
      if (!mounted || id != widget.mediaId) return;
      setState(() {
        if (r is ThumbnailImage) {
          _path = r.path;
        } else if (widget.videoPath == null) {
          _none = true;
        }
      });
      // a video: its poster, as the grids and 浏览 show it
      if (r is! ThumbnailImage && widget.videoPath != null) {
        final poster = await videoPoster(
          FeedItem(media_id: id, post_id: '', ordinal: 0, kind: MediaKind.video, path: widget.videoPath!),
          side,
          dir,
        );
        if (!mounted || id != widget.mediaId) return;
        setState(() {
          _path = poster;
          _none = poster == null;
        });
      }
    } catch (e) {
      debugPrint('CoreThumbnail $id: $e');
      if (mounted) setState(() => _none = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _path;
    if (p != null) {
      final px = (widget.size * MediaQuery.devicePixelRatioOf(context)).ceil();
      return Image(image: ResizeImage.resizeIfNeeded(px, null, localFileImage(p)), fit: BoxFit.cover, gaplessPlayback: true);
    }
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: _none ? Icon(widget.video ? Icons.videocam_outlined : Icons.image_outlined, color: scheme.onSurfaceVariant) : null,
    );
  }
}
