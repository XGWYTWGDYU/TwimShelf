import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/actions/quick_download.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/settings/downloads_page.dart';
import 'package:twimshelf/services/downloads.dart';

import '../services/downloads_test.dart' show FakeCore, MemoryStore;

const _link = 'https://x.com/synthetic/status/1';
const _links = ValueKey('quickDownloadLinks');
const _start = ValueKey('quickDownloadStart');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
    await L10n.load(locale: const Locale('zh', 'CN'));
  });
  late FakeCore core;
  late DownloadService service;

  Future<void> pump(WidgetTester t) async {
    await t.runAsync(() async {
      core = FakeCore();
      service = DownloadService(core: core, store: MemoryStore(), pollInterval: const Duration(days: 1));
      await service.initialize();
    });
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          Builder(
            builder: (button) => IconButton(key: const ValueKey('open'), icon: const Icon(Icons.download), onPressed: () => showQuickDownload(button, downloads: service)),
          ),
        ]),
      ),
    ));
  }

  Future<void> open(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('open')));
    await t.pumpAndSettle();
  }

  Future<void> settle(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
  }

  // inside each test: its status poll timer has to be gone before the test ends
  Future<void> finish(WidgetTester t) => t.runAsync(service.close);

  bool startEnabled(WidgetTester t) => t.widget<FilledButton>(find.byKey(_start)).onPressed != null;

  testWidgets('a small card opens under the button, not a page', (t) async {
    await pump(t);
    await open(t);
    expect(find.byType(DownloadsPage), findsNothing);
    expect(find.byType(QuickDownloadCard), findsOneWidget);
    final card = t.getRect(find.byType(QuickDownloadCard));
    final button = t.getRect(find.byKey(const ValueKey('open')));
    expect(card.width, 380);
    expect(card.top, greaterThanOrEqualTo(button.bottom));
    expect(card.right, closeTo(button.right, 12));
    await finish(t);
  });

  testWidgets('download starts the links and closes; empty cannot start', (t) async {
    await pump(t);
    await open(t);
    expect(startEnabled(t), isFalse);
    await t.enterText(find.byKey(_links), _link);
    await t.pump();
    expect(startEnabled(t), isTrue);
    await t.tap(find.byKey(_start));
    await settle(t);
    expect(find.byType(QuickDownloadCard), findsNothing);
    expect(core.starts.single.urls, [_link]);
    expect(core.starts.single.revive, isTrue);
    await open(t);
    expect(t.widget<TextField>(find.byKey(_links)).controller!.text, isEmpty);
    await finish(t);
  });

  testWidgets('an unrecognized link stays in the card with the reason; nothing starts', (t) async {
    await pump(t);
    await open(t);
    await t.enterText(find.byKey(_links), 'not a link');
    await t.pump();
    await t.tap(find.byKey(_start));
    await settle(t);
    expect(find.byType(QuickDownloadCard), findsOneWidget);
    expect(find.text(L('settings.links.unrecognized')), findsOneWidget);
    expect(core.starts, isEmpty);
    await t.enterText(find.byKey(_links), '');
    await t.pump();
    await finish(t);
  });

  testWidgets('closing keeps the links; the settings button carries them over', (t) async {
    await pump(t);
    await open(t);
    await t.enterText(find.byKey(_links), _link);
    await t.pump();
    await t.tapAt(const Offset(5, 500));
    await t.pumpAndSettle();
    expect(find.byType(QuickDownloadCard), findsNothing);
    await open(t);
    expect(t.widget<TextField>(find.byKey(_links)).controller!.text, _link);
    await t.tap(find.byKey(const ValueKey('quickDownloadSettings')));
    await t.pumpAndSettle();
    expect(find.byType(QuickDownloadCard), findsNothing);
    expect(t.widget<TextField>(find.byKey(const ValueKey('download-links'))).controller!.text, _link);
    expect(core.starts, isEmpty);
    await finish(t);
  });

  testWidgets('the keyboard shortcut downloads', (t) async {
    await pump(t);
    await open(t);
    await t.enterText(find.byKey(_links), _link);
    await t.pump();
    final modifier = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await t.sendKeyDownEvent(modifier);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(modifier);
    await settle(t);
    expect(core.starts.single.urls, [_link]);
    await finish(t);
  });

  testWidgets('a double click brings in the post links on the clipboard, silently, and tries again next time', (t) async {
    String? clip = 'look https://x.com/synthetic/status/77 and https://example.com/a';
    var asked = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      asked++;
      return clip == null ? null : {'text': clip};
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(t);
    await t.tap(find.byKey(const ValueKey('open')));
    await settle(t);
    Future<void> twice() async {
      await t.tap(find.byKey(_links));
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(find.byKey(_links));
      await t.pump(const Duration(milliseconds: 400));
    }
    // refused: nothing is said, and the next time it asks again
    final link = clip;
    clip = null;
    await twice();
    expect(asked, 1);
    expect(t.widget<TextField>(find.byKey(_links)).controller!.text, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    clip = link;
    await twice();
    expect(asked, 2);
    expect(t.widget<TextField>(find.byKey(_links)).controller!.text, 'https://x.com/synthetic/status/77');
    // a repeat is not added twice
    await twice();
    expect(t.widget<TextField>(find.byKey(_links)).controller!.text, 'https://x.com/synthetic/status/77');
    await finish(t);
  });
}
