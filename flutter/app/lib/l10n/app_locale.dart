
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n.dart';

/// Tells the text engine which language the app is in. Chinese and Japanese share code points but
/// not glyphs (直, 骨, 海, 今…): without a language, the fonts are guessed character by character,
/// which gives Japanese forms and uneven weights inside one Chinese line.
abstract final class AppLocale {
  static const supported = [
    Locale('en'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('ja'),
  ];

  static const delegates = [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  /// The language of the app's own strings (`L10n.languageTag`).
  static Locale get current => localeOf(L10n.languageTag);
  static Locale localeOf(String tag) => switch (tag) {
        'zh-Hans' => supported[1],
        'zh-Hant' => supported[2],
        'ja' => supported[3],
        _ => supported[0],
      };

  /// CJK fonts of this system, the app's language first: a post in another language still finds
  /// its characters. Latin text stays in the platform's own font. Android chooses by language.
  static List<String>? get fontFallback => fontsFor(L10n.languageTag, defaultTargetPlatform);

  @visibleForTesting
  static List<String>? fontsFor(String tag, TargetPlatform platform) {
    final byLanguage = switch (platform) {
      TargetPlatform.windows => const {
          'zh-Hans': ['Microsoft YaHei UI', 'Microsoft YaHei'],
          'zh-Hant': ['Microsoft JhengHei UI', 'Microsoft JhengHei'],
          'ja': ['Yu Gothic UI', 'Meiryo UI', 'Meiryo'],
        },
      TargetPlatform.linux => const {
          'zh-Hans': ['Noto Sans CJK SC', 'Source Han Sans SC', 'Noto Sans SC', 'WenQuanYi Micro Hei'],
          'zh-Hant': ['Noto Sans CJK TC', 'Source Han Sans TC', 'Noto Sans TC'],
          'ja': ['Noto Sans CJK JP', 'Source Han Sans JP', 'Noto Sans JP', 'IPAGothic'],
        },
      TargetPlatform.macOS || TargetPlatform.iOS => const {
          'zh-Hans': ['PingFang SC'],
          'zh-Hant': ['PingFang TC'],
          'ja': ['Hiragino Sans'],
        },
      _ => null,
    };
    if (byLanguage == null) return null;
    // English: Simplified Chinese, then the others
    const order = {'zh-Hans': ['zh-Hans', 'zh-Hant', 'ja'], 'zh-Hant': ['zh-Hant', 'zh-Hans', 'ja'], 'ja': ['ja', 'zh-Hans', 'zh-Hant']};
    return [for (final l in order[tag] ?? order['zh-Hans']!) ...byLanguage[l]!];
  }
}
