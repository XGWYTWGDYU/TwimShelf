import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/ai/auto_tagger.dart';
import 'package:twimshelf/ai/external_models.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/secrets.dart';

MediaRef media(int id, {String kind = 'photo'}) => MediaRef(
  media_id: 'm${id.toString().padLeft(3, '0')}',
  path: '/synthetic/$id',
  kind: kind,
  text: 'synthetic post',
);

class FakeCore implements TaggingCore {
  FakeCore(this.items);
  final List<MediaRef> items;
  final events = <String>[];
  final attempted = <String>{}, analysed = <String>{};
  final reasons = <String, String>{};
  final applied =
      <
        ({
          String id,
          String model,
          List<String> labels,
          bool replace,
          int epoch,
        })
      >[];
  final pages = <String>[];
  int vocabularyReads = 0, epochValue = 7;
  bool rejectApply = false;
  @override
  Future<int> epoch() async => epochValue;
  @override
  Future<({int done, int total})> counts() async =>
      (done: analysed.length, total: items.length);
  @override
  Future<int> failures() async => reasons.length;
  @override
  Future<List<MediaRef>> pending(String model, int since, int limit) async =>
      items
          .where(
            (m) =>
                !analysed.contains(m.media_id) &&
                !attempted.contains(m.media_id),
          )
          .take(limit)
          .toList();
  @override
  Future<List<MediaRef>> page(String after, int limit) async {
    pages.add(after);
    return items
        .where((m) => m.media_id.compareTo(after) > 0)
        .take(limit)
        .toList();
  }

  @override
  Future<List<String>> vocabulary() async {
    vocabularyReads++;
    return List.generate(160, (i) => 'tag$i');
  }

  @override
  Future<List<String>> existing(String id) async => ['existing-$id'];
  @override
  Future<void> attempt(
    AiAttemptStep step,
    String id,
    String model, {
    String reason = '',
  }) async {
    events.add('${step.name}:$id');
    if (step == AiAttemptStep.begin) attempted.add(id);
    if (step == AiAttemptStep.failed) reasons[id] = reason;
    if (step == AiAttemptStep.undo) {
      attempted.remove(id);
      reasons.remove(id);
    }
  }

  @override
  Future<void> apply(
    String id,
    String model,
    List<String> labels,
    bool replace,
    int epoch,
  ) async {
    if (rejectApply || epoch != epochValue) throw StateError('epoch changed');
    events.add('apply:$id');
    analysed.add(id);
    applied.add((
      id: id,
      model: model,
      labels: labels,
      replace: replace,
      epoch: epoch,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExternalModels models;
  late ExternalAI api;
  final runners = <AutoTagger>[];
  setUp(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    models = ExternalModels(await SharedPreferences.getInstance(), shared: memorySettings(), secrets: SecretStore(MemorySecretBackend()),
    );
    await models.save(
      const ExternalModel(
        id: 'ext:test',
        name: 'synthetic',
        url: 'http://synthetic.invalid',
        model: 'synthetic',
      ),
    );
    api = ExternalAI(models);
  });
  tearDown(() async {
    for (final runner in runners) {
      await runner.close();
      runner.dispose();
    }
    runners.clear();
    models.dispose();
    api.close();
  });
  AutoTagger runner(
    FakeCore core, {
    TaggingImageLoader? load,
    TaggingInference? infer,
    void Function()? changed,
    DateTime Function()? now,
  }) {
    final value = AutoTagger(
      models: models,
      ai: api,
      cacheDirectory: '/synthetic/cache',
      core: core,
      imageLoader: load ?? (_) async => '/synthetic/picture.jpg',
      infer: infer ?? (_, _, _, _, _, _) async => ['cat'],
      now: now ?? () => DateTime.fromMillisecondsSinceEpoch(100000),
      onChanged: changed,
    );
    runners.add(value);
    return value;
  }

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 1));
  test(
    'automatic ordering, attempts, context, vocab refresh and epoch writes',
    () async {
      final core = FakeCore(List.generate(12, media));
      var calls = 0, changes = 0;
      final value = runner(
        core,
        changed: () => changes++,
        infer: (model, jpeg, existing, vocab, text, cancel) async {
          expect(model.id, 'ext:test');
          expect(vocab, hasLength(150));
          expect(existing, ['existing-${media(calls).media_id}']);
          expect(text, 'synthetic post');
          calls++;
          return ['cat'];
        },
      );
      value.start(const TaggingJob(model: 'ext:test'));
      await value.settled;
      expect(core.applied.map((r) => r.id), core.items.map((m) => m.media_id));
      expect(core.events.take(2), ['begin:m000', 'apply:m000']);
      expect(
        core.applied.every(
          (r) => r.model == 'ext:test' && r.epoch == 7 && !r.replace,
        ),
        true,
      );
      expect(core.vocabularyReads, 2);
      expect(changes, 1);
      expect(value.done, 12);
      expect(value.outcome, 'succeeded');
    },
  );
  test('a slow model shows each picture\'s tags while the run goes on, not all at its end', () async {
    // an on-device model on a phone: about six seconds a picture, ten pictures
    final core = FakeCore(List.generate(10, media));
    var clock = DateTime.fromMillisecondsSinceEpoch(100000);
    final shownBefore = <int>[];
    late AutoTagger value;
    value = runner(
      core,
      now: () => clock,
      changed: () => shownBefore.add(core.applied.length),
      infer: (_, _, _, _, _, _) async {
        clock = clock.add(const Duration(seconds: 6));
        return ['cat'];
      },
    );
    value.start(const TaggingJob(model: 'ext:test'));
    await value.settled;
    expect(core.applied, hasLength(10));
    // the grid reloaded after every picture, each time with that picture's tags written
    expect(shownBefore, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });
  test(
    'autotag preference, model availability and already analysed skips',
    () async {
      final core = FakeCore([media(0), media(1)])..analysed.add('m000');
      final value = runner(core);
      await models.setActiveTagger('ext:test');
      await models.setAutoTag(false);
      await value.startIfEnabled();
      expect(value.running, false);
      await models.setAutoTag(true);
      await value.startIfEnabled();
      await value.settled;
      expect(core.applied.single.id, 'm001');
      value.start(const TaggingJob(model: 'on-device'));
      expect(value.lastError?.kind, ExternalFailureKind.noModel);
    },
  );
  test(
    'three model errors give attempts back once per launch and stop',
    () async {
      final core = FakeCore(List.generate(5, media));
      final value = runner(
        core,
        infer: (_, _, _, _, _, _) async =>
            throw const ExternalFailure(ExternalFailureKind.http, status: 503),
      );
      value.start(const TaggingJob(model: 'ext:test'));
      await value.settled;
      expect(core.events.where((e) => e.startsWith('undo:')), [
        'undo:m000',
        'undo:m001',
        'undo:m002',
      ]);
      expect(core.attempted, isEmpty);
      expect(value.outcome, 'failed');
      value.start(const TaggingJob(model: 'ext:test'));
      await value.settled;
      expect(core.events.where((e) => e.startsWith('undo:')), hasLength(3));
      expect(core.attempted, {'m000', 'm001', 'm002'});
    },
  );
  test('unreadable files do not count toward model error streak or stop later work', () async {
    final core = FakeCore(List.generate(5, media));
    final value = runner(
      core,
      load: (m) async => m.media_id == 'm004' ? '/synthetic/m004.jpg' : null,
    );
    value.start(const TaggingJob(model: 'ext:test'));
    await value.settled;
    expect(core.applied.single.id, 'm004');
    expect(core.reasons, hasLength(4));
    expect(value.lastError, isNull);
  });
  test('success resets model error streak', () async {
    final core = FakeCore(List.generate(6, media));
    var number = 0;
    final value = runner(
      core,
      infer: (_, _, _, _, _, _) async {
        number++;
        if (number % 3 != 0) {
          throw const ExternalFailure(ExternalFailureKind.empty);
        }
        return ['ok'];
      },
    );
    value.start(const TaggingJob(model: 'ext:test'));
    await value.settled;
    expect(core.applied, hasLength(2));
    expect(value.lastError, isNull);
    expect(core.events.where((e) => e.startsWith('undo:')), isEmpty);
  });
  test('selected retag preserves caller order and replacement only with nonempty labels', () async {
    final core = FakeCore([media(0), media(1)]);
    var number = 0;
    final value = runner(
      core,
      infer: (_, _, _, _, _, _) async => number++ == 0 ? [] : ['cat'],
    );
    value.retag([media(1), media(0)], model: 'ext:test', replaceOld: true);
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m001', 'm000']);
    expect(core.applied.map((r) => r.replace), [false, true]);
    expect(core.events.where((e) => e.startsWith('begin:')), isEmpty);
  });
  test(
    'whole-library retag pages in stable id order, ignores automatic skips',
    () async {
      final core = FakeCore(List.generate(20, media))
        ..analysed.addAll({'m000', 'm001'});
      final value = runner(core);
      value.retagAll(model: 'ext:test', replaceOld: true);
      await value.settled;
      expect(core.applied, hasLength(20));
      expect(core.pages, ['', 'm015', 'm019']);
      expect(value.done, 20);
      expect(core.events.where((e) => e.startsWith('begin:')), isEmpty);
    },
  );
  test(
    'pause cancels request, resumes whole job after last completed item',
    () async {
      final core = FakeCore(List.generate(3, media));
      final entered = Completer<void>();
      var block = true;
      final value = runner(
        core,
        infer: (_, _, _, _, _, cancel) async {
          if (block && core.applied.length == 1) {
            entered.complete();
            await cancel.future;
            cancel.check();
          }
          return ['cat'];
        },
      );
      value.retagAll(model: 'ext:test');
      await entered.future;
      value.pause();
      await value.settled;
      expect(value.paused, true);
      expect(core.applied.map((r) => r.id), ['m000']);
      block = false;
      value.resume();
      await value.settled;
      expect(core.applied.map((r) => r.id), ['m000', 'm001', 'm002']);
      expect(value.done, 3);
    },
  );
  test('re-tag everything while an automatic run is on a picture the engine cannot stop: all of it after that picture', () async {
    final core = FakeCore(List.generate(5, media));
    final entered = Completer<void>(), finish = Completer<void>();
    var first = true;
    final value = runner(
      core,
      // the on-device engine finishes the picture it has started, then the call says cancelled
      infer: (_, _, _, _, _, cancel) async {
        if (first) {
          first = false;
          entered.complete();
          await finish.future;
          cancel.check();
        }
        return ['cat'];
      },
    );
    value.start(const TaggingJob(model: 'ext:test'));
    await entered.future;
    value.retagAll(model: 'ext:test');
    finish.complete();
    await value.settled;
    expect(core.applied.map((r) => r.id), List.generate(5, (i) => media(i).media_id));
    expect(value.outcome, 'succeeded');
    expect(value.done, 5);
  });
  test('selected retag preempts whole run then queued run resumes', () async {
    final core = FakeCore(List.generate(3, media));
    final entered = Completer<void>();
    var first = true;
    final value = runner(
      core,
      infer: (_, _, _, _, _, cancel) async {
        if (first) {
          first = false;
          entered.complete();
          await cancel.future;
          cancel.check();
        }
        return ['cat'];
      },
    );
    value.retagAll(model: 'ext:test');
    await entered.future;
    value.retag([media(2)], model: 'ext:test');
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m002', 'm000', 'm001', 'm002']);
  });
  test('pausing selected media goes on with the rest of them, not from the start and not never', () async {
    final core = FakeCore(List.generate(3, media));
    final entered = Completer<void>();
    var block = true;
    final value = runner(
      core,
      infer: (_, _, _, _, _, cancel) async {
        if (block && core.applied.length == 1) {
          entered.complete();
          await cancel.future;
          cancel.check();
        }
        return ['cat'];
      },
    );
    value.retag(List.generate(3, media), model: 'ext:test');
    await entered.future;
    value.pause();
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m000']);
    block = false;
    value.resume();
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m000', 'm001', 'm002']);
  });

  test('stopping while paused leaves nothing stuck: the next job runs', () async {
    final core = FakeCore(List.generate(2, media));
    final value = runner(core, infer: (_, _, _, _, _, _) async => ['cat']);
    value.pause();
    value.stop();
    expect(value.paused, false);
    value.retag([media(0)], model: 'ext:test');
    await tick();
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m000']);
  });

  test('a stop holds until someone asks: a change to the library does not undo it', () async {
    final core = FakeCore(List.generate(2, media));
    final value = runner(core, infer: (_, _, _, _, _, _) async => ['cat']);
    await models.setActiveTagger('ext:test');
    await models.setAutoTag(true);
    value.stop();
    await value.startIfEnabled();
    await value.settled;
    expect(core.applied, isEmpty);
    await value.startIfEnabled(asked: true);
    await tick();
    await value.settled;
    expect(core.applied.length, 2);
  });

  test('a re-tag that could not do a picture says so instead of succeeding', () async {
    final core = FakeCore(List.generate(2, media));
    var calls = 0;
    final value = runner(
      core,
      infer: (_, _, _, _, _, _) async {
        if (calls++ == 0) throw const ExternalFailure(ExternalFailureKind.timeout);
        return ['cat'];
      },
    );
    value.retag(List.generate(2, media), model: 'ext:test');
    await tick();
    await value.settled;
    expect(core.applied.map((r) => r.id), ['m001']);
    expect(value.lastError?.kind, ExternalFailureKind.timeout);
    expect(value.outcome, 'partial');
  });

  test(
    'cancel clears queue and returns counted attempt; no late tag write',
    () async {
      final core = FakeCore([media(0)]);
      final entered = Completer<void>();
      final value = runner(
        core,
        infer: (_, _, _, _, _, cancel) async {
          entered.complete();
          await cancel.future;
          cancel.check();
          return [];
        },
      );
      value.start(const TaggingJob(model: 'ext:test'));
      await entered.future;
      value.retagAll(model: 'ext:test');
      value.cancel();
      await value.settled;
      expect(core.applied, isEmpty);
      expect(core.events, ['begin:m000', 'undo:m000']);
      expect(value.outcome, 'cancelled');
      await tick();
      expect(value.running, false);
    },
  );
  test(
    'epoch/write failure returns attempt and stops without replacing tags',
    () async {
      final core = FakeCore([media(0)])..rejectApply = true;
      final value = runner(core);
      value.start(const TaggingJob(model: 'ext:test'));
      await value.settled;
      expect(core.events, ['begin:m000', 'undo:m000']);
      expect(core.applied, isEmpty);
      expect(value.outcome, 'failed');
      // the page says why, not only "didn't finish"
      expect(value.lastError?.detail, contains('epoch changed'));
    },
  );
  test('a re-tag whose write the core refuses ends saying why', () async {
    final core = FakeCore(List.generate(3, media))..rejectApply = true;
    final value = runner(core);
    value.retagAll(model: 'ext:test');
    await value.settled;
    expect(core.applied, isEmpty);
    expect(value.outcome, 'failed');
    expect(value.lastError?.kind, ExternalFailureKind.transport);
    expect(value.lastError?.detail, contains('epoch changed'));
  });
}

SharedSettings memorySettings() {
  final values = <String, String>{};
  return SharedSettings((k) => values[k], (k, v) => v == null ? values.remove(k) : values[k] = v);
}
