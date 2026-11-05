import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/ai/external_models.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/secrets.dart';

const prompt = AiPrompt(
  system: 'S',
  prompt: 'Q',
  context: 'Context: {text}',
  existing: 'Existing: {existing}',
  vocabulary: 'Vocabulary: {tags}',
);
const model = ExternalModel(
  id: 'ext:test',
  url: 'https://synthetic.invalid',
  model: 'synthetic',
);
Matcher failure(ExternalFailureKind kind) =>
    isA<ExternalFailure>().having((e) => e.kind, 'kind', kind);

class PromptBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
    Uint8List.fromList(
      utf8.encode(
        '# comment\n[system]\nNative system\n[prompt]\nNative question\n[existing]\nReuse {existing}\n[vocabulary]\nUse {tags}\n[context]\nPost {text}',
      ),
    ),
  );
}

class BrokenSecrets implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('secret backend');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('secret backend');
  @override
  Future<void> delete(String key) async => throw StateError('secret backend');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late Map<String, String> shared;
  late SharedSettings settings;
  late SecretStore secrets;
  late ExternalModels models;
  setUp(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    secrets = SecretStore(MemorySecretBackend());
    shared = {};
    settings = SharedSettings((k) => shared[k], (k, v) => v == null ? shared.remove(k) : shared[k] = v);
    models = ExternalModels(preferences, secrets: secrets, defaults: prompt, shared: settings);
    await models.initialize();
    await models.save(model);
  });
  test(
    'all four bundled defaults preserve the approved native resources',
    () async {
      for (final language in ['en', 'ja', 'zh-Hans', 'zh-Hant']) {
        final native = await File(
          '../../native/Resources/$language.lproj/AIPrompt.txt',
        ).readAsString();
        expect(await File('assets/ai/$language.txt').readAsString(), native);
        final loaded = await AiPrompt.bundledDefaults(language: language);
        final expected = native
            .split('[prompt]')
            .last
            .split('[existing]')
            .first
            .trim();
        expect(loaded.prompt, expected);
      }
    },
  );
  test('partial saved prompts use native catalog fallbacks and bundled tag templates', () async {
    shared['ai.prompt'] = '{"prompt":"Custom"}';
    final p = models.promptFor('m');
    expect(p.prompt, 'Custom');
    expect(p.system, L('prompt.default.system'));
    expect(p.existing, prompt.existing);
    expect(p.vocabulary, prompt.vocabulary);
  });
  test(
    'bundled native sections and locale reload override catalog fallbacks',
    () async {
      final native = await AiPrompt.bundledDefaults(
        bundle: PromptBundle(),
        language: 'en',
      );
      expect(native.system, 'Native system');
      expect(native.prompt, 'Native question');
      await models.reloadDefaults(bundle: PromptBundle());
      expect(models.promptFor('m').prompt, 'Native question');
    },
  );
  test('connection probe sends only a synthetic gray JPEG', () async {
    final api = ExternalAI(
      models,
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final uri =
            body['messages'][1]['content'][1]['image_url']['url'] as String;
        final picture = image.decodeJpg(base64Decode(uri.split(',').last))!;
        expect(picture.width, 64);
        expect(picture.height, 64);
        expect(picture.getPixel(32, 32).r, closeTo(128, 2));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '["gray"]'},
              },
            ],
          }),
          200,
        );
      }),
    );
    expect(await api.test(model), ['gray']);
  });
  test('credential-bearing URL cannot enter model preferences', () async {
    await expectLater(
      models.save(
        const ExternalModel(
          id: 'ext:bad',
          url: 'https://host.invalid/?key=querySecret',
        ),
      ),
      throwsA(failure(ExternalFailureKind.badUrl)),
    );
    expect(
      shared['ai.external'],
      isNot(contains('querySecret')),
    );
  });
  test(
    'models and their prompts are shared, secrets never',
    () async {
      await models.setApiKey(model, 'synthetic-key');
      const custom = AiPrompt(system: 'S2', prompt: 'custom', context: 'C', existing: 'E', vocabulary: 'V');
      await models.savePromptFor(model.id, custom);
      expect(models.promptFor(model.id).prompt, 'custom');
      expect(models.promptFor('other').prompt, 'Q');
      expect(shared['ai.external'], contains('ext:test'));
      expect(shared['ai.modelPrompt.${model.id}'], contains('custom'));
      expect(shared.values.join(), isNot(contains('synthetic-key')));
      expect(preferences.getKeys().map(preferences.get).join(), isNot(contains('synthetic-key')));
      expect(await models.apiKey(model), 'synthetic-key');
      await models.remove(model.id);
      expect(models.all, isEmpty);
      expect(
        (await secrets.read(
          'ai.key.${model.id}',
        ) as SecretValue<String?>).value,
        isNull,
      );
    },
  );
  test(
    'keys bind to normalized origin and never follow a changed service',
    () async {
      await models.setApiKey(model, 'key');
      expect(
        await models.apiKey(
          const ExternalModel(
            id: 'ext:test',
            url: 'https://SYNTHETIC.invalid:443/v1',
          ),
        ),
        'key',
      );
      for (final url in [
        'http://synthetic.invalid',
        'https://other.invalid',
        'https://synthetic.invalid:444',
      ]) {
        expect(
          await models.apiKey(ExternalModel(id: model.id, url: url)),
          isNull,
        );
      }
    },
  );
  test('legacy key binds once; unavailable secrets fail closed', () async {
    await secrets.write('ai.key.${model.id}', 'legacy');
    expect(await models.apiKey(model), 'legacy');
    expect(
      (await secrets.read(
        'ai.keyorigin.${model.id}',
      ) as SecretValue<String?>).value,
      model.origin,
    );
    final broken = ExternalModels(
      preferences,
      secrets: SecretStore(BrokenSecrets()),
      shared: settings,
    );
    await expectLater(
      broken.apiKey(model),
      throwsA(failure(ExternalFailureKind.secretsUnavailable)),
    );
    await expectLater(
      broken.setApiKey(model, 'secret'),
      throwsA(failure(ExternalFailureKind.secretsUnavailable)),
    );
  });
  test(
    'default prompt version migration and corrupt stored data recover',
    () async {
      await preferences.setString('ai.prompt', '{"prompt":"old"}');
      await preferences.setInt('ai.prompt.version', 1);
      await models.initialize();
      expect(models.promptFor('m').prompt, 'Q');
      // what this device kept before moves to the account
      shared.remove('ai.external');
      await preferences.setString('ai.external', '[{"id":"ext:a","name":"","url":"http://x","model":""}]');
      await models.initialize();
      expect(models.all.single.id, 'ext:a');
      expect(preferences.getString('ai.external'), isNull);
      shared['ai.prompts'] = 'not json';
      shared['ai.modelPrompts'] = '{"x":2}';
      expect(models.promptFor('x').prompt, 'Q');
      shared['ai.external'] = '[{}]';
      expect(models.all, isEmpty);
      // an old assigned prompt set still holds, until the model gets its own
      shared['ai.prompts'] = '[{"id":"s","name":"n","prompt":{"prompt":"from set"}}]';
      shared['ai.modelPrompts'] = '{"x":"s"}';
      expect(models.promptFor('x').prompt, 'from set');
      await models.savePromptFor('x', prompt);
      expect(models.promptFor('x').prompt, 'Q');
    },
  );
  test(
    'serial preference saves retain concurrent updates and native settings',
    () async {
      await Future.wait([
        models.save(const ExternalModel(id: 'ext:a')),
        models.save(const ExternalModel(id: 'ext:b')),
      ]);
      expect(models.all.map((m) => m.id), ['ext:test', 'ext:a', 'ext:b']);
      await models.setAutoTag(false);
      await models.setActiveTagger(model.id);
      expect(preferences.getBool('ai.autotag'), false);
      expect(preferences.getString('ai.tagger.id'), model.id);
      final generated = ExternalModel.create();
      expect(
        generated.id,
        matches(
          RegExp(
            r'^ext:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    },
  );
  test('endpoint normalization matches native supported forms', () {
    for (final url in [
      'https://synthetic.invalid',
      'https://synthetic.invalid/v1/',
      'https://synthetic.invalid/v1/chat/completions',
      'https://synthetic.invalid/v1/models',
    ]) {
      expect(
        ExternalAI.endpoint(url, 'models').toString(),
        'https://synthetic.invalid/v1/models',
      );
    }
    expect(
      ExternalAI.endpoint('localhost:11434', 'chat/completions').toString(),
      'http://localhost:11434/v1/chat/completions',
    );
    for (final url in [
      'file:///tmp/a',
      'https://',
      'https://user:secret@synthetic.invalid',
      'https://synthetic.invalid?key=a',
      'https://synthetic.invalid#part',
    ]) {
      expect(
        () => ExternalAI.endpoint(url, 'models'),
        throwsA(failure(ExternalFailureKind.badUrl)),
      );
    }
  });
  test(
    'request canonical bytes equal Foundation oracle, with exact native keys',
    () async {
      final body = ExternalAI.body(
        model: 'synthetic',
        system: 'S',
        question: 'Q',
        jpeg: [255, 216, 255, 0],
      );
      expect(
        utf8.encode(body),
        await File('test/ai/fixtures/swift_request.json').readAsBytes(),
      );
    },
  );
  test(
    'question omits empty sections and cleans context by grapheme count',
    () {
      expect(prompt.question(), 'Q');
      expect(
        prompt.question(
          existing: ['cat'],
          vocabulary: ['wall'],
          postText: ' @someone hello https://example.invalid/a ',
        ),
        'Q\n\nExisting: cat\n\nVocabulary: wall\n\nContext: hello',
      );
      expect(AiPrompt.cleanContext('https://example.invalid @u'), isNull);
      expect(
        AiPrompt.cleanContext(
          List.filled(301, '\u{1f469}\u200d\u{1f4bb}').join(),
        ),
        '${List.filled(300, '\u{1f469}\u200d\u{1f4bb}').join()}\u2026',
      );
    },
  );
  test(
    'answers accept text and parts, and reject every empty/malformed shape',
    () {
      expect(
        ExternalAI.answer(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '["cat"]'},
                },
              ],
            }),
          ),
        ),
        '["cat"]',
      );
      expect(
        ExternalAI.answer(
          utf8.encode(
            '{"choices":[{"message":{"content":[{"text":"a"},{"image":1},{"text":"b"}]}}]}',
          ),
        ),
        'ab',
      );
      for (final text in [
        '{}',
        '{"choices":[]}',
        '{"choices":[{"message":{"content":""}}]}',
        '{"choices":[{"message":{"content":[]}}]}',
      ]) {
        expect(
          () => ExternalAI.answer(utf8.encode(text)),
          throwsA(failure(ExternalFailureKind.empty)),
        );
      }
      expect(
        () => ExternalAI.answer([0xff]),
        throwsA(failure(ExternalFailureKind.invalidResponse)),
      );
    },
  );
  test('tag parser matches native JSON, think, delimiters, trim, dedupe and limits', () {
    expect(
      ExternalAI.parseTags(
        'reason</think> [" CAT ","cat",1,"(Wall).", "abcdefghijklmnop"]',
      ),
      ['cat', 'wall'],
    );
    expect(
      ExternalAI.parseTags("'Cat'\uFF0Cdog\u3001bird; fish\uFF1Bsky\n#sun"),
      ['cat', 'dog', 'bird', 'fish', 'sky', 'sun'],
    );
    expect(
      ExternalAI.parseTags(List.generate(14, (i) => 't$i').join(',')),
      hasLength(12),
    );
    expect(ExternalAI.parseTags('[1,null]'), isEmpty);
  });
  test('HTTP picks first model, sends key and native image body', () async {
    await models.setApiKey(model, 'key');
    final seen = <http.Request>[];
    final api = ExternalAI(
      models,
      client: MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode(
            request.method == 'GET'
                ? {
                    'data': [
                      {'id': 'first'},
                    ],
                  }
                : {
                    'choices': [
                      {
                        'message': {'content': '["cat"]'},
                      },
                    ],
                  },
          ),
          200,
        );
      }),
    );
    final local = ExternalModel(id: model.id, url: model.url);
    expect(await api.tags(model: local, jpeg: [1, 2]), ['cat']);
    expect(seen, hasLength(2));
    expect(seen.first.headers['Authorization'], 'Bearer key');
    expect(jsonDecode(seen.last.body)['model'], 'first');
    expect(seen.last.followRedirects, false);
    api.close();
  });
  test(
    'explicit model skips discovery and unavailable/empty model lists fail',
    () async {
      var calls = 0;
      final api = ExternalAI(
        models,
        client: MockClient((request) async {
          calls++;
          return http.Response('{"data":[]}', 200);
        }),
      );
      expect(await api.modelName(model), 'synthetic');
      expect(calls, 0);
      await expectLater(
        api.modelName(ExternalModel(id: model.id, url: model.url)),
        throwsA(failure(ExternalFailureKind.noModel)),
      );
    },
  );
  test(
    'HTTP error variants and transport errors never reveal the key',
    () async {
      await models.setApiKey(model, 'synthetic-secret');
      for (final body in [
        '{"error":{"message":"synthetic-secret bad"}}',
        '{"error":"synthetic-secret bad"}',
        'synthetic-secret bad',
      ]) {
        final api = ExternalAI(
          models,
          client: MockClient((_) async => http.Response(body, 401)),
        );
        try {
          await api.availableModels(model);
          fail('expected failure');
        } on ExternalFailure catch (error) {
          expect(error.kind, ExternalFailureKind.http);
          expect(error.status, 401);
          expect(error.detail, isNot(contains('synthetic-secret')));
          expect(error.toString(), isNot(contains('synthetic-secret')));
        }
      }
      final api = ExternalAI(
        models,
        client: MockClient(
          (_) async => throw const SocketException('synthetic-secret'),
        ),
      );
      await expectLater(
        api.availableModels(model),
        throwsA(failure(ExternalFailureKind.transport)),
      );
    },
  );
  test(
    'invalid, oversized responses and timeouts are typed failures',
    () async {
      for (final body in [
        'not JSON',
        List.filled(2 * 1024 * 1024 + 1, 'x').join(),
      ]) {
        final api = ExternalAI(
          models,
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          api.availableModels(model),
          throwsA(failure(ExternalFailureKind.invalidResponse)),
        );
      }
      final api = ExternalAI(
        models,
        timeout: const Duration(milliseconds: 10),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.availableModels(model),
        throwsA(failure(ExternalFailureKind.timeout)),
      );
    },
  );
  test(
    'cancellation interrupts even a fake client that ignores abort requests',
    () async {
      final response = Completer<http.Response>();
      final entered = Completer<void>();
      final cancellation = AiCancellation();
      final api = ExternalAI(
        models,
        client: MockClient((_) {
          entered.complete();
          return response.future;
        }),
      );
      final request = api.availableModels(model, cancellation: cancellation);
      final checked = expectLater(
        request,
        throwsA(failure(ExternalFailureKind.cancelled)),
      );
      await entered.future;
      cancellation.cancel();
      await checked;
      response.complete(http.Response('{}', 200));
      await expectLater(
        api.availableModels(model, cancellation: cancellation),
        throwsA(failure(ExternalFailureKind.cancelled)),
      );
    },
  );
}
