import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/actions/search_export.dart';
import 'package:twimshelf/app/identity.g.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/search/query.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.load(locale: const Locale('zh', 'CN'));
  });

  test('only the words searched for are in the name, and the app says what it is called', () {
    final query = TokenQuery.parse('猫咪 帖文 -狗');
    expect(query.terms, ['猫咪']);
    expect(searchExportName(query.terms), '$appName 猫咪搜索结果');
  });

  test('nothing searched for, and what no system accepts in a name', () {
    expect(searchExportName(const []), '$appName 搜索结果');
    expect(searchExportName(const ['a/b:c']), '$appName a b c搜索结果');
    expect(searchExportName(const ['猫', '狗']), '$appName 猫 狗搜索结果');
  });
}
