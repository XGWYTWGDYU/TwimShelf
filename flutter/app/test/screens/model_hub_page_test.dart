import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/ai/local_models.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/model_hub_page.dart';

const _device = HubDevice(memory_bytes: 16000000000, free_bytes: 100000000000);

class _FakeApi extends ModelHubApi {
  _FakeApi({this.page, this.failure, this.detail});
  final HubPage? page;
  final Object? failure;
  final HubDetail? detail;
  final queries = <(String, bool, String?)>[];

  @override
  HubDevice? device() => _device;
  @override
  Future<HubPage> search(String format, String query, bool uncensored, String? next) async {
    queries.add((query, uncensored, next));
    if (failure != null) throw failure!;
    return page ?? const HubPage(device: _device);
  }

  @override
  Future<HubDetail> repo(String format, String repo) async => detail!;
}

const _good = HubRepo(repo: 'a/fits-GGUF', format: 'gguf', architecture: 'qwen2vl', params: 3000000000, estimated_bytes: 2250000000, tier: 'recommended', sha: 'x');
const _claim = HubRepo(repo: 'a/claims-abliterated-GGUF', format: 'gguf', tier: 'usable', claims_uncensored: true);
const _big = HubRepo(repo: 'a/big-GGUF', format: 'gguf', tier: 'tooLarge', estimated_bytes: 20000000000);
const _curated = CatalogEntry(repo: 'c/m', format: 'gguf', role: 'tagger', name_key: 'catalog.gguf.qwen25vl3b', note_key: 'catalog.note.gguf.small', bytes: 2860000000, folder: 'c--m--w', weights: 'w.gguf', tier: 'recommended');

Future<void> _pump(WidgetTester t, ModelHubApi api) async {
  await t.pumpWidget(MaterialApp(home: ModelHubPage(local: LocalModels.forTest(const [_curated]), api: api)));
  await t.pump();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load();
  });
  // everything on one tall screen
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 4000);
    view.devicePixelRatio = 1;
  });

  testWidgets('what fits shows first, and what does not is counted and one tap away', (t) async {
    await _pump(t, _FakeApi(page: const HubPage(device: _device, items: [_good, _claim, _big])));
    expect(find.byKey(const ValueKey('hub-repo-a/fits-GGUF')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-repo-a/big-GGUF')), findsNothing);
    final over = find.byKey(const ValueKey('hub-over'));
    await t.tap(over);
    await t.pump();
    expect(find.byKey(const ValueKey('hub-repo-a/big-GGUF')), findsOneWidget);
  });

  testWidgets('results that cannot be used are listed with their reason', (t) async {
    await _pump(t, _FakeApi(page: const HubPage(device: _device, hidden: [HubHidden(repo: 'a/q3-GGUF', reason: 'engine reason')])));
    final hidden = find.byKey(const ValueKey('hub-hidden'));
    await t.tap(hidden);
    await t.pumpAndSettle();
    expect(find.text('a/q3-GGUF'), findsOneWidget);
    expect(find.text('engine reason'), findsOneWidget);
  });

  testWidgets('the curated list leads until a search, then the search asks the API', (t) async {
    final api = _FakeApi(page: const HubPage(device: _device, items: [_good]));
    await _pump(t, api);
    expect(find.byKey(const ValueKey('hub-curated-c--m--w')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('hub-search')), 'qwen');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('hub-curated-c--m--w')), findsNothing);
    expect(api.queries.last, ('qwen', false, null));
    await t.tap(find.byKey(const ValueKey('hub-claim')));
    await t.pump();
    expect(api.queries.last, ('qwen', true, null));
  });

  testWidgets('a next page is asked for with its address and adds to the list', (t) async {
    final api = _FakeApi(page: const HubPage(device: _device, items: [_good], next: 'https://huggingface.co/api/models?cursor=x'));
    await _pump(t, api);
    final more = find.byKey(const ValueKey('hub-more'));
    await t.tap(more);
    await t.pump();
    expect(api.queries.last.$3, 'https://huggingface.co/api/models?cursor=x');
    expect(find.byKey(const ValueKey('hub-repo-a/fits-GGUF')), findsOneWidget, reason: 'the same repo is not listed twice');
  });

  testWidgets('a failure says what happened and can be tried again', (t) async {
    final api = _FakeApi(failure: 'no network');
    await _pump(t, api);
    expect(find.text('no network'), findsOneWidget);
    await t.tap(find.text(L('models.retry')));
    await t.pump();
    expect(api.queries, hasLength(2));
  });

  testWidgets('a repo shows each version, what is not offered, and asks before downloading', (t) async {
    const detail = HubDetail(repo: _good, revision: 'f982a07559d4a2f6c8744d840bf6fccab30eea96', variants: [
      HubVariant(label: 'Q4_K_M', weights: 'm-Q4_K_M.gguf', projector: 'mmproj.gguf', bytes: 2800000000, tier: 'recommended', suggested: true, folder: 'a--fits-GGUF--m-Q4_K_M'),
      HubVariant(label: 'F32', weights: 'm-f32.gguf', projector: 'mmproj.gguf', bytes: 90000000000, tier: 'tooLarge', enough_space: false, folder: 'a--fits-GGUF--m-f32'),
    ], skipped: [HubSkipped(name: 'x-00001-of-00002.gguf', reason: 'split')]);
    await t.pumpWidget(MaterialApp(home: ModelHubRepoPage(local: LocalModels.forTest(const []), api: _FakeApi(detail: detail), repo: 'a/fits-GGUF')));
    await t.pump();
    await t.pump();
    expect(find.text(L('hub.variant.suggested', ['Q4_K_M'])), findsOneWidget);
    final full = find.byKey(const ValueKey('hub-variant-F32'));
    expect(find.descendant(of: full, matching: find.byIcon(Icons.download)), findsNothing, reason: 'no room: it cannot be started');
    expect(find.text('x-00001-of-00002.gguf'), findsOneWidget);
    final dl = find.descendant(of: find.byKey(const ValueKey('hub-variant-Q4_K_M')), matching: find.byIcon(Icons.download));
    await t.tap(dl);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-confirm')), findsOneWidget);
    await t.tap(find.text(L('common.cancel')));
    await t.pumpAndSettle();
  });

  testWidgets('a repo that cannot be installed says why', (t) async {
    const detail = HubDetail(repo: _good, revision: 'x', problem: 'not a vision model');
    await t.pumpWidget(MaterialApp(home: ModelHubRepoPage(local: LocalModels.forTest(const []), api: _FakeApi(detail: detail), repo: 'a/fits-GGUF')));
    await t.pump();
    await t.pump();
    expect(find.text('not a vision model'), findsOneWidget);
  });
}
