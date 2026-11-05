// Isolated acceptance host; never imports or changes the product UI.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:tl_core/tl_core.dart';
import 'package:image/image.dart' as image;
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/video.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await L10n.load();
  final source = Platform.environment['TL_VIDEO_PATH']!;
  final report = File(Platform.environment['TL_VIDEO_REPORT']!);
  final library = await Directory.systemTemp.createTemp('f7a-smoke-library-');
  if (!Core.open(library.path)) throw const CoreError('app.openFailed');
  final player = VideoPlayback();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: VideoSurface(
        controller: player.surfaceController,
        controls: NoVideoControls,
      ),
    ),
  );
  try {
    await player.setMuted(true);
    await player.setLoop(true);
    await player.open(source);
    final advanced = await player.position
        .firstWhere((p) => p > const Duration(milliseconds: 250))
        .timeout(const Duration(seconds: 15));
    final poster = await videoPoster(
      FeedItem(
        media_id: 'synthetic-video',
        post_id: 'synthetic',
        ordinal: 0,
        kind: MediaKind.video,
        path: source,
      ),
      384,
      '${library.path}/posters',
    );
    if (poster == null) throw StateError('video.posterFailed');
    final bytes = await File(poster).readAsBytes();
    final decoded = image.decodeJpg(bytes)!;
    if (decoded.width != 384 || decoded.height != 384) {
      throw StateError('video.posterSize');
    }
    await player.pause();
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await player.dispose();
    await report.writeAsString(
      jsonEncode({
        'position_ms': advanced.inMilliseconds,
        'poster': poster,
        'width': decoded.width,
        'height': decoded.height,
        'jpeg': bytes[0] == 255 && bytes[1] == 216,
        'disposed': true,
      }),
      flush: true,
    );
    debugPrint(
      'video-smoke position_ms=${advanced.inMilliseconds} square_jpeg=true disposed=true',
    );
  } catch (error) {
    await report.writeAsString(
      jsonEncode({'error': error.toString()}),
      flush: true,
    );
    rethrow;
  }
}
