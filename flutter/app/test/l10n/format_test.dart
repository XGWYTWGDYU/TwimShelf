import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/l10n/l10n.dart';

void main() {
  test('zero-padded integers (the pairing code countdown)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load();
    expect(L('sync.code.expires', [4, 59]), contains('4:59'));
    expect(L('sync.code.expires', [0, 7]), contains('0:07'));
  });
}
