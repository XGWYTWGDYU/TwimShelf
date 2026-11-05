import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/l10n/app_locale.dart';

void main() {
  test('each language has its own locale, with its script', () {
    expect(AppLocale.localeOf('zh-Hans').scriptCode, 'Hans');
    expect(AppLocale.localeOf('zh-Hant').scriptCode, 'Hant');
    expect(AppLocale.localeOf('ja').languageCode, 'ja');
    expect(AppLocale.localeOf('en').languageCode, 'en');
  });

  test('the fonts of the language come first', () {
    expect(AppLocale.fontsFor('zh-Hans', TargetPlatform.windows)!.first, 'Microsoft YaHei UI');
    expect(AppLocale.fontsFor('zh-Hant', TargetPlatform.windows)!.first, 'Microsoft JhengHei UI');
    expect(AppLocale.fontsFor('ja', TargetPlatform.windows)!.first, 'Yu Gothic UI');
    expect(AppLocale.fontsFor('zh-Hans', TargetPlatform.linux)!.first, 'Noto Sans CJK SC');
    expect(AppLocale.fontsFor('ja', TargetPlatform.macOS)!.first, 'Hiragino Sans');
    expect(AppLocale.fontsFor('zh-Hant', TargetPlatform.iOS)!.first, 'PingFang TC');
    expect(AppLocale.fontsFor('zh-Hans', TargetPlatform.android), isNull, reason: 'Android chooses by language');
  });

  testWidgets('Chinese text gets the Chinese locale and system strings', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: AppLocale.localeOf('zh-Hans'),
      supportedLocales: AppLocale.supported,
      localizationsDelegates: AppLocale.delegates,
      home: const Scaffold(body: Text('下载状态')),
    ));
    final context = tester.element(find.text('下载状态'));
    expect(Localizations.localeOf(context).scriptCode, 'Hans');
    expect(MaterialLocalizations.of(context).okButtonLabel, '确定');
    expect(tester.renderObject<RenderParagraph>(find.text('下载状态')).locale?.scriptCode, 'Hans', reason: 'what picks the glyphs');
  });
}
