import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/l10n/app_locale.dart';

/// Draws the characters that differ between Chinese and Japanese in each language, through the
/// app's own settings, into CJK_SHEET (to look at on the platform in question).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sheet', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1400, 800);
    addTearDown(tester.view.reset);
    const text = '直骨海今角 关门写 下载状态';
    final key = GlobalKey();
    Widget line(String tag) => MaterialApp(
          locale: AppLocale.localeOf(tag),
          supportedLocales: AppLocale.supported,
          localizationsDelegates: AppLocale.delegates,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, fontFamilyFallback: AppLocale.fontsFor(tag, defaultTargetPlatform)),
          home: Scaffold(body: Padding(padding: const EdgeInsets.all(4), child: Text('$tag  $text', style: const TextStyle(fontSize: 34)))),
        );
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [for (final t in ['zh-Hans', 'zh-Hant', 'ja', 'en']) Expanded(child: line(t))]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final out = Platform.environment['CJK_SHEET'];
    if (out == null) return;
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(out).writeAsBytes(png!.buffer.asUint8List());
    });
  });
}
