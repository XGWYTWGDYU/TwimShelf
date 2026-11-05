import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';

import '../app/identity.g.dart';

// ignore: non_constant_identifier_names
String L(String key, [List<Object?> args = const []]) => L10n.format(key, args);

/// Load once before building the app, and again when the device locale changes.
/// Include assets/l10n/ in the application's asset bundle.
class L10n {
  L10n._();
  static const languages = ['en', 'zh-Hans', 'zh-Hant', 'ja'];
  static String _languageTag = tagForLocale(PlatformDispatcher.instance.locale);
  static String get languageTag => _languageTag;
  static Map<String, Map<String, dynamic>> _catalogs = {};

  static String tagForLocale(Locale locale) {
    final language = locale.languageCode.toLowerCase();
    if (language == 'zh') {
      // The script is the language; the region only says where the person is (zh-Hans-TW is
      // Simplified). Only a system that names no script (zh-TW on Windows, Linux) needs the region.
      final script = locale.scriptCode?.toLowerCase();
      if (script != null) return script == 'hant' ? 'zh-Hant' : 'zh-Hans';
      return const ['TW', 'HK', 'MO'].contains(locale.countryCode?.toUpperCase()) ? 'zh-Hant' : 'zh-Hans';
    }
    return language == 'ja' ? 'ja' : 'en';
  }

  static Future<void> load({Locale? locale, AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final catalogs = <String, Map<String, dynamic>>{};
    for (final language in languages) {
      catalogs[language] = jsonDecode(
        await assets.loadString('assets/l10n/$language.json'),
      ) as Map<String, dynamic>;
    }
    // Publish a complete set atomically, so an interrupted load keeps old data.
    _catalogs = catalogs;
    _languageTag = tagForLocale(locale ?? PlatformDispatcher.instance.locale);
  }

  static String _template(String key, String language, List<Object?> args) {
    final value = _catalogs[language]?[key] ?? _catalogs['en']?[key];
    if (value is String) return value;
    if (value is Map) {
      int? count;
      for (final argument in args) {
        if (argument is int) {
          count = argument;
          break;
        }
      }
      final form = language == 'en' && count == 1 ? 'one' : 'other';
      return (value[form] ?? value['other'] ?? value['one'] ?? key) as String;
    }
    return key;
  }

  static String format(String key, List<Object?> args) =>
      _format(_template(key, languageTag, args), args).replaceAll('{app}', appName);

  static List<String> everyLanguage(String key) {
    final values = <String>[format(key, const [])];
    for (final language in languages) {
      if (_catalogs[language]?.containsKey(key) ?? false) {
        final value = _format(_template(key, language, const []), const []);
        if (!values.contains(value)) values.add(value);
      }
    }
    return values;
  }

  static final _specifier = RegExp(
    r"%%|%(?:(\d+)\$)?([-+ #0']*)(\d*)(?:\.(\d+))?(?:ll|hh|[lhqztj])?([@diufFeEgGxXo])",
  );

  static String _format(String template, List<Object?> args) {
    // Swift returns the untranslated format verbatim when there are no arguments.
    if (args.isEmpty) return template;
    var next = 0;
    return template.replaceAllMapped(_specifier, (match) {
      if (match[0] == '%%') return '%';
      final index = match[1] == null ? next++ : int.parse(match[1]!) - 1;
      if (index < 0 || index >= args.length) return match[0]!;
      final argument = args[index];
      final kind = match[5]!;
      final precision = int.tryParse(match[4] ?? '');
      String value;
      if (kind == '@') {
        value = argument.toString();
      } else if ('fFeEgG'.contains(kind)) {
        final number = argument is num
            ? argument.toDouble()
            : double.tryParse('$argument') ?? 0;
        final finite = number.isFinite ? number : 0.0;
        value = 'eE'.contains(kind)
            ? finite.toStringAsExponential(precision ?? 6)
            : 'gG'.contains(kind)
            ? finite.toStringAsPrecision(precision ?? 6)
            : finite.toStringAsFixed(precision ?? 6);
        if (kind == kind.toUpperCase()) value = value.toUpperCase();
      } else {
        final number = argument is num
            ? (argument.isFinite ? argument.toInt() : 0)
            : int.tryParse('$argument') ?? 0;
        final radix = 'xX'.contains(kind)
            ? 16
            : kind == 'o'
            ? 8
            : 10;
        value = number.toRadixString(radix);
        if (kind == 'X') value = value.toUpperCase();
      }
      final flags = match[2]!;
      if (kind != '@' && !value.startsWith('-')) {
        if (flags.contains('+')) {
          value = '+$value';
        } else if (flags.contains(' ')) {
          value = ' $value';
        }
      }
      final width = int.tryParse(match[3]!) ?? 0;
      if (flags.contains('-')) return value.padRight(width);
      if (flags.contains('0') && kind != '@' && value.isNotEmpty) {
        if ('-+ '.contains(value[0])) {
          return value[0] +
              value.substring(1).padLeft(width > 0 ? width - 1 : 0, '0');
        }
        return value.padLeft(width, '0');
      }
      return value.padLeft(width);
    });
  }
}
