import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/platform/secrets.dart';

class FakeBackend implements SecretBackend {
  final values = <String, String>{};
  String? failingKey;
  bool unavailable = false;
  void check(String key) {
    if (unavailable || key == failingKey) {
      throw PlatformException(
        code: 'unavailable',
        message: 'secret-not-for-logs',
      );
    }
  }

  @override
  Future<String?> read(String key) async {
    check(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    check(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    check(key);
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('write/read/delete and missing value', () async {
    final store = SecretStore(FakeBackend());
    expect(
      (await store.read('auth_token') as SecretValue<String?>).value,
      isNull,
    );
    expect(
      await store.write('auth_token', 'synthetic'),
      isA<SecretValue<void>>(),
    );
    expect(
      (await store.read('auth_token') as SecretValue<String?>).value,
      'synthetic',
    );
    await store.delete('auth_token');
    expect(
      (await store.read('auth_token') as SecretValue<String?>).value,
      isNull,
    );
  });
  test('empty writes remove values like the native wrapper', () async {
    final backend = FakeBackend()..values['ct0'] = 'synthetic';
    await SecretStore(backend).write('ct0', '');
    expect(backend.values, isEmpty);
  });
  test('unavailable backend fails closed for every operation', () async {
    final backend = FakeBackend()..unavailable = true;
    final store = SecretStore(backend);
    expect(await store.read('ct0'), isA<SecretsUnavailable<String?>>());
    expect(
      await store.write('ct0', 'synthetic'),
      isA<SecretsUnavailable<void>>(),
    );
    expect(await store.delete('ct0'), isA<SecretsUnavailable<void>>());
    expect(backend.values, isEmpty);
  });
  test('session applyStoredCookies is a no-op since cookies live in synced core store', () async {
    final backend = FakeBackend()..unavailable = true;
    final calls = <List<String>>[];
    expect(
      await Session.applyStoredCookies(
        store: SecretStore(backend),
        setCookies: (a, b) => calls.add([a, b]),
      ),
      isA<SecretValue<void>>(),
    );
    expect(calls, isEmpty);
  });
}
