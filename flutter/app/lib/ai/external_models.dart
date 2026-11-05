import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';

import 'local_models.dart';
import '../l10n/l10n.dart';
import '../platform/secrets.dart';
import '../platform/system_random.dart';

enum ExternalFailureKind {
  badUrl,
  http,
  noModel,
  empty,
  invalidResponse,
  transport,
  timeout,
  cancelled,
  secretsUnavailable,
  unreadable,
}

class ExternalFailure implements Exception {
  const ExternalFailure(this.kind, {this.status, this.detail = ''});
  final ExternalFailureKind kind;
  final int? status;
  // Sanitized server text, never a request/header/credential. Never log it.
  final String detail;
  String get messageKey => switch (kind) {
    ExternalFailureKind.badUrl => 'models.external.err.url',
    ExternalFailureKind.http => 'models.external.err.status',
    ExternalFailureKind.noModel => 'models.external.err.noModel',
    ExternalFailureKind.empty ||
    ExternalFailureKind.invalidResponse => 'models.external.err.empty',
    ExternalFailureKind.unreadable => 'ai.err.unreadable',
    _ => 'common.notDone',
  };
  String get message {
    final label = L(messageKey, status == null ? [] : [status]);
    return detail.isEmpty ? label : L('format.labelValue', [label, detail]);
  }

  @override
  String toString() => messageKey;
}

class AiCancellation {
  final _cancelled = Completer<void>();
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get future => _cancelled.future;
  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () {
      _listeners.remove(listener);
    };
  }

  void check() {
    if (isCancelled) throw const ExternalFailure(ExternalFailureKind.cancelled);
  }
}

String _uuid() {
  const random = SystemRandom();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ExternalModel {
  const ExternalModel({
    required this.id,
    this.name = '',
    this.url = '',
    this.model = '',
  });
  factory ExternalModel.create() => ExternalModel(id: 'ext:${_uuid()}');
  final String id, name, url, model;
  String get host =>
      Uri.tryParse(url)?.host.isNotEmpty == true ? Uri.parse(url).host : url;
  String get title => name.isNotEmpty
      ? name
      : model.isNotEmpty
      ? model
      : host;
  String get origin {
    final value = url.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null || uri.host.isEmpty) return value.toLowerCase();
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    return '$scheme://${host.contains(':') && !host.startsWith('[') ? '[$host]' : host}:${uri.hasPort
        ? uri.port
        : scheme == 'https'
        ? 443
        : 80}';
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'model': model,
  };
  factory ExternalModel.fromJson(Map<String, dynamic> data) => ExternalModel(
    id: data['id'] as String,
    name: data['name'] as String,
    url: data['url'] as String,
    model: data['model'] as String,
  );
}

class AiPrompt {
  const AiPrompt({
    required this.system,
    required this.prompt,
    required this.context,
    required this.existing,
    required this.vocabulary,
  });
  final String system, prompt, context, existing, vocabulary;
  factory AiPrompt.catalogDefaults() => AiPrompt(
    system: L('prompt.default.system'),
    prompt: L('prompt.default.prompt'),
    context: L('prompt.default.context'),
    existing: L('prompt.default.existing'),
    vocabulary: L('prompt.default.vocabulary'),
  );
  static Future<AiPrompt> bundledDefaults({
    AssetBundle? bundle,
    String? language,
  }) async {
    final fallback = AiPrompt.catalogDefaults();
    try {
      final raw = await (bundle ?? rootBundle).loadString(
        'assets/ai/${language ?? L10n.languageTag}.txt',
      );
      final sections = <String, String>{};
      String? section;
      var lines = <String>[];
      void flush() {
        final value = lines.join('\n').trim();
        if (section != null && value.isNotEmpty) sections[section] = value;
        lines = [];
      }

      for (final line in const LineSplitter().convert(raw)) {
        if (line.startsWith('#')) continue;
        final text = line.trim();
        if (text.startsWith('[') && text.endsWith(']')) {
          flush();
          section = text.substring(1, text.length - 1);
        } else {
          lines.add(line);
        }
      }
      flush();
      return AiPrompt.fromJson(sections, defaults: fallback);
    } catch (_) {
      return fallback;
    }
  }

  factory AiPrompt.fromJson(Map<String, dynamic> data, {AiPrompt? defaults}) {
    final catalog = AiPrompt.catalogDefaults();
    final base = defaults ?? catalog;
    return AiPrompt(
      system: data['system'] as String? ?? catalog.system,
      prompt: data['prompt'] as String? ?? catalog.prompt,
      context: data['context'] as String? ?? catalog.context,
      existing: data['existing'] as String? ?? base.existing,
      vocabulary: data['vocabulary'] as String? ?? base.vocabulary,
    );
  }
  Map<String, String> toJson() => {
    'system': system,
    'prompt': prompt,
    'context': context,
    'existing': existing,
    'vocabulary': vocabulary,
  };
  String question({
    List<String> existing = const [],
    List<String> vocabulary = const [],
    String? postText,
  }) {
    var question = prompt;
    if (existing.isNotEmpty) {
      question +=
          '\n\n${this.existing.replaceAll('{existing}', existing.join(L('list.separator')))}';
    }
    if (vocabulary.isNotEmpty) {
      question +=
          '\n\n${this.vocabulary.replaceAll('{tags}', vocabulary.join(L('list.separator')))}';
    }
    final clean = cleanContext(postText);
    if (clean != null) question += '\n\n${context.replaceAll('{text}', clean)}';
    return question;
  }

  static String? cleanContext(String? text) {
    final value = text
        ?.replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'@[A-Za-z0-9_]{1,15}'), '')
        .trim();
    if (value == null || value.isEmpty) return null;
    return value.characters.length > 300
        ? '${value.characters.take(300)}\u2026'
        : value;
  }
}

/// Per-device preferences as requested by E1; keys match the native names.
/// Keep one owner and initialize after L10n.load. Credentials never enter prefs.
/// Settings every device of the sync account shares.
class SharedSettings {
  const SharedSettings(this.read, this.write);
  final String? Function(String key) read;
  final void Function(String key, String? value) write;
}

class ExternalModels extends ChangeNotifier {
  ExternalModels(this.preferences, {SecretStore? secrets, AiPrompt? defaults, SharedSettings? shared})
    : secrets = secrets ?? Secrets.store,
      shared = shared ?? const SharedSettings(Core.setting, Core.setSetting),
      defaults = defaults ?? AiPrompt.catalogDefaults();
  /// What stays on this device: which model is the default, automatic tagging.
  final SharedPreferences preferences;
  /// What every device of the account shares: the external models, the prompts.
  final SharedSettings shared;
  final SecretStore secrets;
  AiPrompt defaults;
  static Future<ExternalModels> create({
    SecretStore? secrets,
    AssetBundle? bundle,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final defaults = await AiPrompt.bundledDefaults(bundle: bundle);
    final result = ExternalModels(
      preferences,
      secrets: secrets,
      defaults: defaults,
    );
    await result.initialize();
    return result;
  }

  Future<void> reloadDefaults({AssetBundle? bundle}) => _serial(() async {
    defaults = await AiPrompt.bundledDefaults(bundle: bundle);
    notifyListeners();
  });
  Future<void> _writes = Future.value();
  static bool isExternal(String id) => id.startsWith('ext:');
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _writes.then((_) => work());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _set(String key, Object? value) async {
    final success = value == null
        ? await preferences.remove(key)
        : value is bool
        ? await preferences.setBool(key, value)
        : value is int
        ? await preferences.setInt(key, value)
        : await preferences.setString(key, value as String);
    if (!success) throw const ExternalFailure(ExternalFailureKind.transport);
  }

  List<dynamic> _array(String key) {
    try {
      return jsonDecode(shared.read(key) ?? '[]') as List;
    } catch (_) {
      return [];
    }
  }

  List<ExternalModel> get all {
    try {
      return List.unmodifiable(
        _array('ai.external')
            .map((v) => ExternalModel.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return [];
    }
  }

  ExternalModel? find(String id) {
    for (final model in all) {
      if (model.id == id) return model;
    }
    return null;
  }

  Future<void> save(ExternalModel model) => _serial(() async {
    if (!isExternal(model.id)) throw ArgumentError.value(model.id);
    if (model.url.trim().isNotEmpty) ExternalAI.endpoint(model.url, 'models');
    final list = all.toList();
    final index = list.indexWhere((m) => m.id == model.id);
    if (index < 0) {
      list.add(model);
    } else {
      list[index] = model;
    }
    shared.write('ai.external', jsonEncode(list.map((m) => m.toJson()).toList()));
    notifyListeners();
  });
  Future<void> remove(String id) => _serial(() async {
    await _saveKey(id, null, null);
    final list = all.where((m) => m.id != id).map((m) => m.toJson()).toList();
    shared.write('ai.external', list.isEmpty ? null : jsonEncode(list));
    shared.write('$_promptKey$id', null);
    notifyListeners();
  });
  Future<void> _saveKey(String id, String? key, String? origin) async {
    Future<void> require(Future<SecretResult<void>> result) async {
      if (await result is! SecretValue<void>) {
        throw const ExternalFailure(ExternalFailureKind.secretsUnavailable);
      }
    }

    // Fail closed across partial writes; a credential never acquires a new
    // origin without the old credential first being removed.
    await require(secrets.delete('ai.key.$id'));
    if (key == null || key.isEmpty) {
      await require(secrets.delete('ai.keyorigin.$id'));
      return;
    }
    await require(secrets.write('ai.keyorigin.$id', origin!));
    await require(secrets.write('ai.key.$id', key));
  }

  Future<void> setApiKey(ExternalModel model, String? key) => _serial(() {
    if (key != null && key.isNotEmpty) ExternalAI.endpoint(model.url, 'models');
    return _saveKey(model.id, key, model.origin);
  });
  Future<String?> apiKey(ExternalModel model) => _serial(() async {
    final value = await secrets.read('ai.key.${model.id}');
    final bound = await secrets.read('ai.keyorigin.${model.id}');
    if (value is! SecretValue<String?> || bound is! SecretValue<String?>) {
      throw const ExternalFailure(ExternalFailureKind.secretsUnavailable);
    }
    final key = value.value;
    if (key == null || key.isEmpty) return null;
    if (bound.value == null || bound.value!.isEmpty) {
      if (await secrets.write('ai.keyorigin.${model.id}', model.origin)
          is! SecretValue<void>) {
        throw const ExternalFailure(ExternalFailureKind.secretsUnavailable);
      }
      return key;
    }
    return bound.value == model.origin ? key : null;
  });
  static const _promptKey = 'ai.modelPrompt.';

  AiPrompt? _decoded(String? raw) {
    if (raw == null) return null;
    try {
      return AiPrompt.fromJson(jsonDecode(raw) as Map<String, dynamic>, defaults: defaults);
    } catch (_) {
      return null;
    }
  }

  /// The prompt [model] tags with: its own, shared by every device of the account whenever a
  /// device gets that model. A model that never had one starts from the default; before models
  /// had their own, a prompt set could be assigned to one, and that one still holds.
  AiPrompt promptFor(String model) =>
      _decoded(shared.read('$_promptKey$model')) ?? _assigned(model) ?? _decoded(shared.read('ai.prompt')) ?? defaults;

  AiPrompt? _assigned(String model) {
    try {
      final set = (jsonDecode(shared.read('ai.modelPrompts') ?? '{}') as Map)[model];
      if (set == null) return null;
      for (final v in _array('ai.prompts')) {
        if ((v as Map)['id'] == set) return AiPrompt.fromJson(v['prompt'] as Map<String, dynamic>, defaults: defaults);
      }
    } catch (_) {}
    return null;
  }

  /// Also when it is the default: this model then stays on it, whatever an old setting says.
  Future<void> savePromptFor(String model, AiPrompt prompt) => _serial(() async {
    shared.write('$_promptKey$model', jsonEncode(prompt.toJson()));
    notifyListeners();
  });

  /// What this app kept on the device before these were shared moves to the account, unless
  /// another device has already given a value.
  Future<void> initialize() => _serial(() async {
    if ((preferences.getInt('ai.prompt.version') ?? 0) < 2) {
      await _set('ai.prompt', null);
      await _set('ai.prompt.version', 2);
    }
    for (final key in const ['ai.external', 'ai.prompt', 'ai.prompts', 'ai.modelPrompts']) {
      final local = preferences.getString(key);
      if (local == null) continue;
      if (shared.read(key) == null) shared.write(key, local);
      await preferences.remove(key);
    }
  });

  /// 清除所有数据: the API keys always go; the models' settings too with [settings].
  Future<void> forget({required bool settings}) => _serial(() async {
    for (final m in all) {
      await secrets.delete('ai.key.${m.id}');
      await secrets.delete('ai.keyorigin.${m.id}');
    }
    if (settings) {
      for (final key in preferences.getKeys().where((k) => k.startsWith('ai.')).toList()) {
        await preferences.remove(key);
      }
    }
    notifyListeners();
  });

  /// A tagger when there is none or the chosen one has gone: the recommended of what is installed.
  Future<void> adoptInstalled(LocalModels local) async {
    final id = activeTaggerId;
    final vision = local.installed.where((m) => m.vision).toList();
    if (id != null && (isExternal(id) ? find(id) != null : local.find(id) != null)) return;
    if (vision.isEmpty) {
      if (id != null) await setActiveTagger(null);
      return;
    }
    // the one that asks least of the device; the person can choose another
    vision.sort((a, b) => (local.catalogFor(a.id)?.recommend_gb ?? 1 << 30).compareTo(local.catalogFor(b.id)?.recommend_gb ?? 1 << 30));
    await setActiveTagger(vision.first.id);
  }

  bool get autoTag => preferences.getBool('ai.autotag') ?? true;
  String? get activeTaggerId => preferences.getString('ai.tagger.id');
  Future<void> setAutoTag(bool value) => _serial(() async {
    await _set('ai.autotag', value);
    notifyListeners();
  });
  Future<void> setActiveTagger(String? value) => _serial(() async {
    await _set('ai.tagger.id', value);
    notifyListeners();
  });
}

class ExternalAI {
  ExternalAI(
    this.models, {
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;
  final ExternalModels models;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  static Uri endpoint(String base, String path) {
    var value = base.trim();
    if (!value.contains('://')) value = 'http://$value';
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    for (final tail in ['/chat/completions', '/models']) {
      if (value.endsWith(tail)) {
        value = value.substring(0, value.length - tail.length);
      }
    }
    if (!value.endsWith('/v1')) value += '/v1';
    final uri = Uri.tryParse('$value/$path');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ExternalFailure(ExternalFailureKind.badUrl);
    }
    return uri;
  }

  // Swift JSONSerialization dictionaries have unspecified byte order. Stable
  // sorting allows canonical byte parity; keys/values are exactly the Swift body.
  static String body({
    required String model,
    required String system,
    required String question,
    required List<int> jpeg,
  }) {
    final encoded = jsonEncode({
      'max_tokens': 300,
      'messages': [
        {'content': system, 'role': 'system'},
        {
          'content': [
            {'text': question, 'type': 'text'},
            {
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(jpeg)}',
              },
              'type': 'image_url',
            },
          ],
          'role': 'user',
        },
      ],
      'model': model,
      'stream': false,
      'temperature': 0.1,
    });
    // Foundation NSNumber encodes this Double with 17 significant digits.
    return encoded.replaceFirst(
      '"temperature":0.1}',
      '"temperature":0.10000000000000001}',
    );
  }

  Future<Uint8List> _send(
    ExternalModel model,
    String path, {
    String? body,
    AiCancellation? cancellation,
  }) async {
    cancellation?.check();
    final uri = endpoint(model.url, path);
    final key = await models.apiKey(model);
    cancellation?.check();
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    final interrupted = Completer<Uint8List>();
    final unlisten = cancellation?.listen(() {
      stop();
      if (!interrupted.isCompleted) {
        interrupted.completeError(
          const ExternalFailure(ExternalFailureKind.cancelled),
        );
      }
    });
    final request =
        http.AbortableRequest(
            body == null ? 'GET' : 'POST',
            uri,
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json';
    if (key != null) request.headers['Authorization'] = 'Bearer $key';
    if (body != null) request.body = body;
    Future<Uint8List> read() async {
      final response = await _client.send(request);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          stop();
          throw const ExternalFailure(ExternalFailureKind.invalidResponse);
        }
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String message;
        try {
          final json = jsonDecode(utf8.decode(data));
          final error = json is Map ? json['error'] : null;
          message = error is Map && error['message'] is String
              ? error['message'] as String
              : error is String
              ? error
              : utf8.decode(data.take(200).toList(), allowMalformed: true);
        } catch (_) {
          message = utf8.decode(data.take(200).toList(), allowMalformed: true);
        }
        if (key != null) message = message.replaceAll(key, '');
        throw ExternalFailure(
          ExternalFailureKind.http,
          status: response.statusCode,
          detail: message,
        );
      }
      return data;
    }

    try {
      final result =
          await Future.any([
            read(),
            if (cancellation != null) interrupted.future,
          ]).timeout(
            timeout,
            onTimeout: () {
              stop();
              throw const ExternalFailure(ExternalFailureKind.timeout);
            },
          );
      cancellation?.check();
      return result;
    } on ExternalFailure {
      rethrow;
    } catch (_) {
      cancellation?.check();
      throw const ExternalFailure(ExternalFailureKind.transport);
    } finally {
      unlisten?.call();
    }
  }

  static Object? _json(List<int> data) {
    try {
      return jsonDecode(utf8.decode(data));
    } catch (_) {
      throw const ExternalFailure(ExternalFailureKind.invalidResponse);
    }
  }

  Future<List<String>> availableModels(
    ExternalModel model, {
    AiCancellation? cancellation,
  }) async {
    final json = _json(
      await _send(model, 'models', cancellation: cancellation),
    );
    final data = json is Map ? json['data'] : null;
    return data is List
        ? data
              .whereType<Map>()
              .map((row) => row['id'])
              .whereType<String>()
              .toList()
        : [];
  }

  Future<String> modelName(
    ExternalModel model, {
    AiCancellation? cancellation,
  }) async {
    // Foundation .whitespaces deliberately does not remove newlines.
    final value = model.model.replaceAll(
      RegExp(
        r'^[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+|[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+$',
      ),
      '',
    );
    if (value.isNotEmpty) return value;
    final names = await availableModels(model, cancellation: cancellation);
    if (names.isEmpty) throw const ExternalFailure(ExternalFailureKind.noModel);
    return names.first;
  }

  static String answer(List<int> data) {
    final json = _json(data);
    final choices = json is Map ? json['choices'] : null;
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is String && content.isNotEmpty) return content;
    if (content is List) {
      final value = content
          .whereType<Map>()
          .map((p) => p['text'])
          .whereType<String>()
          .join();
      if (value.isNotEmpty) return value;
    }
    throw const ExternalFailure(ExternalFailureKind.empty);
  }

  static List<String> parseTags(String raw) {
    var value = raw;
    final end = value.indexOf('</think>');
    if (end >= 0) value = value.substring(end + 8);
    List<String>? tags;
    final a = value.indexOf('['), b = value.lastIndexOf(']');
    if (a >= 0 && b > a) {
      try {
        final list = jsonDecode(value.substring(a, b + 1));
        if (list is List) tags = list.whereType<String>().toList();
      } catch (_) {}
    }
    tags ??= value.split(RegExp('[,\uFF0C\u3001;\uFF1B\n#]'));
    final seen = <String>{};
    final result = <String>[];
    final edge = RegExp(
      '^[\\s"\'\u201C\u201D\\[\\]()\uFF08\uFF09\u3002.]+|[\\s"\'\u201C\u201D\\[\\]()\uFF08\uFF09\u3002.]+\$',
    );
    for (final tag in tags) {
      final clean = tag.replaceAll(edge, '').toLowerCase();
      if (clean.isNotEmpty &&
          clean.characters.length <= 12 &&
          seen.add(clean)) {
        result.add(clean);
      }
      if (result.length == 12) break;
    }
    return result;
  }

  Future<List<String>> tags({
    required ExternalModel model,
    required List<int> jpeg,
    List<String> existing = const [],
    List<String> vocabulary = const [],
    String? postText,
    AiCancellation? cancellation,
  }) async {
    final prompt = models.promptFor(model.id);
    final name = await modelName(model, cancellation: cancellation);
    final data = await _send(
      model,
      'chat/completions',
      body: body(
        model: name,
        system: prompt.system,
        question: prompt.question(
          existing: existing,
          vocabulary: vocabulary,
          postText: postText,
        ),
        jpeg: jpeg,
      ),
      cancellation: cancellation,
    );
    return parseTags(answer(data));
  }

  Future<List<String>> test(
    ExternalModel model, {
    AiCancellation? cancellation,
  }) async {
    return tags(
      model: model,
      jpeg: await _grayJpeg(),
      cancellation: cancellation,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

Future<Uint8List> _grayJpeg() => Isolate.run(() {
  final picture = image.Image(width: 64, height: 64, numChannels: 3);
  image.fill(picture, color: image.ColorRgb8(128, 128, 128));
  return Uint8List.fromList(image.encodeJpg(picture, quality: 80));
});
