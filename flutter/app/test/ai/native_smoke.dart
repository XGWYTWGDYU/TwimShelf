// Isolated synthetic acceptance entry point; no widgets or product UI hooks.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/ai/auto_tagger.dart';
import 'package:twimshelf/ai/external_models.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/secrets.dart';

Future<void> _open(String path) => Isolate.run(() {
  if (!Core.open(path)) throw StateError('e1.open');
});
Future<void> _tag(String id) =>
    Isolate.run(() => Core.addTag('synthetic-user', id));
Future<List<FeedItem>> _feed() => Isolate.run(() => Core.feed(FeedRequest()));
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = File(
    Platform.environment['E1_SMOKE_OUTPUT'] ?? '/tmp/e1-native-result.json',
  );
  try {
    await L10n.load(locale: const Locale('en'));
    final root = await Directory.systemTemp.createTemp('e1-native-synthetic-');
    final input = await Directory('${root.path}/input').create();
    for (var i = 0; i < 2; i++) {
      final picture = image.Image(width: 112, height: 112, numChannels: 3);
      image.fill(
        picture,
        color: image.ColorRgb8(i == 0 ? 20 : 0, i == 1 ? 20 : 0, 0),
      );
      await File('${input.path}/$i.png').writeAsBytes(image.encodePng(picture));
    }
    await _open('${root.path}/library');
    await Core.importLooseDirAsync(input.path, consume: false);
    final items = await _feed();
    if (items.length != 2) throw StateError('e1.import');
    await _tag(items.first.media_id);
    SharedPreferences.setMockInitialValues({});
    final models = ExternalModels(await SharedPreferences.getInstance(), shared: memorySettings(), secrets: SecretStore(MemorySecretBackend()),
    );
    // a service on this machine, as the core reaches it: the picture it sends has to be a JPEG
    var label = 'first';
    var calls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      if (request.uri.path.endsWith('/chat/completions')) {
        final json = jsonDecode(body) as Map;
        final uri = json['messages'][1]['content'][1]['image_url']['url'] as String;
        if (image.decodeJpg(base64Decode(uri.split(',').last)) == null) {
          request.response.statusCode = 400;
        } else {
          calls++;
          request.response.write(jsonEncode({
            'choices': [
              {'message': {'content': jsonEncode([label])}},
            ],
          }));
        }
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    await models.save(
      ExternalModel(
        id: 'ext:synthetic',
        url: 'http://127.0.0.1:${server.port}',
        model: 'synthetic',
      ),
    );
    final ai = ExternalAI(models);
    final tagger = AutoTagger(
      models: models,
      ai: ai,
      cacheDirectory: '${root.path}/posters',
    );
    tagger.start(const TaggingJob(model: 'ext:synthetic'));
    await tagger.settled;
    if (tagger.done != 2 || tagger.lastError != null) {
      throw StateError('e1.automatic');
    }
    label = 'second';
    tagger.retagAll(model: 'ext:synthetic', replaceOld: true);
    await tagger.settled;
    final result = await _feed();
    for (final item in result) {
      if (item.tags.any((t) => t.label == 'first')) {
        throw StateError('e1.replace');
      }
      if (!item.tags.any(
        (t) =>
            t.label == 'second' &&
            t.origin == 2 &&
            t.models.contains('ext:synthetic'),
      )) {
        throw StateError('e1.provenance');
      }
    }
    if (!result
        .firstWhere((m) => m.media_id == items.first.media_id)
        .tags
        .any((t) => t.label == 'synthetic-user' && t.origin == 1)) {
      throw StateError('e1.endorsement');
    }
    await tagger.close();
    tagger.dispose();
    ai.close();
    await server.close(force: true);
    models.dispose();
    await output.writeAsString(
      jsonEncode({
        'ok': true,
        'items': result.length,
        'requests': calls,
        'human_preserved': true,
        'old_ai_replaced': true,
        'provenance': true,
        'library': root.path,
      }),
      flush: true,
    );
  } catch (_) {
    await output.writeAsString('{"ok":false}', flush: true);
  }
}

SharedSettings memorySettings() {
  final values = <String, String>{};
  return SharedSettings((k) => values[k], (k, v) => v == null ? values.remove(k) : values[k] = v);
}
