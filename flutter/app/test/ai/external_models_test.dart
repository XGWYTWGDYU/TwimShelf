import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
    await models.save(model);
  });
  test(
    'all four bundled defaults preserve the approved native resources',
    () async {
      for (final language in ['en', 'ja', 'zh-Hans', 'zh-Hant']) {
        final native = await File(
          '../../Apple/Resources/$language.lproj/AIPrompt.txt',
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
    'corrupt stored data recover',
    () async {
      expect(models.promptFor('m').prompt, 'Q');
      shared['ai.external'] = '[{"id":"ext:a","name":"","url":"http://x","model":""}]';
      expect(models.all.single.id, 'ext:a');
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
}
