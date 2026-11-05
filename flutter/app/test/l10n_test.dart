import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:twimshelf/l10n/l10n.dart';

class _CatalogBundle extends CachingAssetBundle {
  _CatalogBundle(this.catalogs);
  final Map<String, Map<String, Object>> catalogs;
  @override
  Future<ByteData> load(String key) async {
    final language = key.split('/').last.replaceAll('.json', '');
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(jsonEncode(catalogs[language] ?? <String, Object>{})),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundle = _CatalogBundle({
    'en': {
      'object': '%@',
      'integer': '%lld %d',
      'decimal': '%.1f',
      'precision': '%.0f %.2f %02d',
      'percent': '%@ %%',
      'position': '%2\$@ %1\$lld %2\$@',
      'mixed': '%2\$@ %@',
      'plural': {'one': '%lld item', 'other': '%lld items'},
      'fallback': 'English fallback',
      'shared': 'English',
      'firstInteger': {'one': '%@ %lld item', 'other': '%@ %lld items'},
      'coerce': '%lld %.1f %@',
      'verbatim': '%lld %%',
      'sign': '%+04d %04d',
    },
    'zh-Hans': {'shared': 'Simplified'},
    'zh-Hant': {'shared': 'Traditional'},
    'ja': {'shared': 'Japanese'},
  });
  setUp(() => L10n.load(locale: const Locale('en'), bundle: bundle));

  test('object, both integers, precision, percent, coercion', () {
    expect(L('object', [42]), '42');
    expect(L('integer', [12.9, '7']), '12 7');
    expect(L('decimal', ['1.25']), '1.3');
    expect(L('precision', [2.1, 1.25, 7]), '2 1.25 07');
    expect(L('percent', ['done']), 'done %');
    expect(L('coerce', ['bad', 'bad', null]), '0 0.0 null');
    expect(L('sign', [2, -2]), '+002 -002');
  });
  test('positional reordering and repeated positions', () {
    expect(L('position', [7, 'text']), 'text 7 text');
    expect(L('mixed', ['first', 'second']), 'second first');
  });
  test('plurals use the first integer argument', () {
    expect(L('plural', [1]), '1 item');
    expect(L('plural', [0]), '0 items');
    expect(L('plural', [2]), '2 items');
    expect(L('firstInteger', ['count', 1]), 'count 1 item');
  });
  test('fallback, missing key, missing argument, no arguments', () async {
    await L10n.load(locale: const Locale('ja'), bundle: bundle);
    expect(L('fallback'), 'English fallback');
    expect(L('missing.key'), 'missing.key');
    expect(L('integer', [2]), '2 %d');
    expect(L('verbatim'), '%lld %%');
    expect(L('plural', [1]), '1 items');
  });
  test('the system language decides, not the region', () {
    expect(
      L10n.tagForLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'TW'),
      ),
      'zh-Hans',
    );
    expect(
      L10n.tagForLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'CN'),
      ),
      'zh-Hant',
    );
  });
  test('locale mapping includes script and Chinese regions', () {
    for (final region in ['TW', 'HK', 'MO']) {
      expect(L10n.tagForLocale(Locale('zh', region)), 'zh-Hant');
    }
    expect(
      L10n.tagForLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
      'zh-Hant',
    );
    expect(
      L10n.tagForLocale(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ),
      'zh-Hans',
    );
    expect(L10n.tagForLocale(const Locale('zh', 'CN')), 'zh-Hans');
    expect(L10n.tagForLocale(const Locale('zh')), 'zh-Hans');
    expect(L10n.tagForLocale(const Locale('ja', 'JP')), 'ja');
    expect(L10n.tagForLocale(const Locale('fr')), 'en');
  });
  test('everyLanguage is unique and current language comes first', () async {
    await L10n.load(locale: const Locale('ja'), bundle: bundle);
    expect(L10n.languageTag, 'ja');
    expect(L10n.everyLanguage('shared'), [
      'Japanese',
      'English',
      'Simplified',
      'Traditional',
    ]);
    expect(L10n.everyLanguage('missing.key'), ['missing.key']);
  });
  test('exported catalog has equal key sets and real translations', () async {
    final catalogs = <String, Map<String, dynamic>>{};
    for (final language in L10n.languages) {
      catalogs[language] = jsonDecode(
        await File('assets/l10n/$language.json').readAsString(),
      );
    }
    for (final language in L10n.languages) {
      expect(catalogs[language]!.keys.toSet(), catalogs['en']!.keys.toSet());
    }
    await L10n.load(locale: const Locale('en'), bundle: rootBundle);
    expect(L('export.search.countMedia', [1]), '1 item');
    expect(L('export.search.countMedia', [3]), '3 items');
    expect(L10n.everyLanguage('common.cancel').length, greaterThan(1));
  });
}
