import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/ai_page.dart';

/// 打标签 settings against a fake OpenAI-compatible service on 127.0.0.1 (nothing leaves the
/// machine): add a model, test the connection, make it the tagger. TL_LIBRARY_DIR: synthetic.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(WidgetTester t, bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('add an external model and test it', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    server.listen((r) async {
      paths.add(r.uri.path);
      await utf8.decodeStream(r);
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({
        'choices': [
          {'message': {'content': 'gray, square'}}
        ]
      }));
      await r.response.close();
    });
    await L10n.load();
    await Prefs.load();
    final library = await LibraryModel.open();
    for (final m in library.aiModels.all) {
      await library.aiModels.remove(m.id);
    }
    await tester.pumpWidget(MaterialApp(home: AiPage(models: library.aiModels, ai: library.ai, tagger: library.tagger)));
    await tester.tap(find.byKey(const ValueKey('ai-add')));
    await until(tester, () => find.byKey(const ValueKey('ai-url')).evaluate().isNotEmpty);
    await tester.enterText(find.byKey(const ValueKey('ai-name')), 'Fake');
    await tester.enterText(find.byKey(const ValueKey('ai-url')), 'http://127.0.0.1:${server.port}/v1');
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'fake-vision');
    await tester.tap(find.byKey(const ValueKey('ai-test')));
    await until(tester, () => find.byKey(const ValueKey('ai-result')).evaluate().isNotEmpty);
    final result = tester.widget<SelectableText>(find.descendant(of: find.byKey(const ValueKey('ai-result')), matching: find.byType(SelectableText))).data!;
    expect(result, startsWith(L('models.external.successColon')), reason: result);
    expect(result, contains('gray'));
    expect(paths.single, '/v1/chat/completions');

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await until(tester, () => find.text('Fake').evaluate().isNotEmpty);
    expect(library.aiModels.all.single.title, 'Fake');
    // turn off automatic tagging so the test does not tag the synthetic library
    await library.aiModels.setAutoTag(false);
    await library.aiModels.setActiveTagger(library.aiModels.all.single.id);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('ai-tagger')), findsOneWidget);

    for (final m in library.aiModels.all) {
      await library.aiModels.remove(m.id);
    }
    await server.close(force: true);
  });
}
