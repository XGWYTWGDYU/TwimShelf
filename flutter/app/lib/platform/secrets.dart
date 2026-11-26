

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'os.dart';

/// No backend error text is exposed: native errors can include sensitive data.
sealed class SecretResult<T> {
  const SecretResult();
}

final class SecretValue<T> extends SecretResult<T> {
  const SecretValue(this.value);
  final T value;
}

/// UI should map this typed result to its localized "secrets unavailable" text.
final class SecretsUnavailable<T> extends SecretResult<T> {
  const SecretsUnavailable();
}

abstract interface class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The system's secret store: Keychain on Apple, Keystore on Android.
class PlatformSecretBackend implements SecretBackend {
  PlatformSecretBackend({
    FlutterSecureStorage? storage,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(
               resetOnError: false,
               storageNamespace: 'org.twimshelf',
             ),
             // Its own Keychain service: the native apps use `org.twimshelf` with the same
             // item names (sync.key, auth_token, ct0), and on macOS the login Keychain is shared,
             // so the Flutter app must never read (or join) the native app's sync account.
             iOptions: IOSOptions(
               accountName: 'org.twimshelf.flutter',
               accessibility: KeychainAccessibility.first_unlock_this_device,
               synchronizable: false,
             ),
             // The login Keychain also supports ad-hoc signed debug apps. No
             // plaintext debug fallback and no dependency on a provisioning team.
             mOptions: MacOsOptions(
               accountName: 'org.twimshelf.flutter',
               usesDataProtectionKeychain: false,
               accessibility: KeychainAccessibility.first_unlock_this_device,
               synchronizable: false,
             ),
           );

  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) async {
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}

class MemorySecretBackend implements SecretBackend {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Injectable instance used by tests and the static application facade.
class SecretStore {
  SecretStore(this.backend);
  final SecretBackend backend;

  Future<SecretResult<T>> _attempt<T>(Future<T> Function() action) async {
    try {
      return SecretValue(await action());
    } catch (_) {
      return SecretsUnavailable<T>();
    }
  }

  Future<SecretResult<String?>> read(String key) =>
      _attempt(() => backend.read(key));
  Future<SecretResult<void>> write(String key, String value) =>
      value.isEmpty ? delete(key) : _attempt(() => backend.write(key, value));
  Future<SecretResult<void>> delete(String key) =>
      _attempt(() => backend.delete(key));
}

class Secrets {
  Secrets._();
  /// A debug run on a synthetic library (TL_LIBRARY_DIR) keeps its secrets in memory: test runs
  /// never read or write the user's Keychain or secret service.
  static final SecretStore store = SecretStore(kDebugMode && OS.environment['TL_LIBRARY_DIR'] != null
      ? MemorySecretBackend()
      // Apple: Keychain; Android: Keystore
      : PlatformSecretBackend());
  static Future<SecretResult<String?>> read(String key) => store.read(key);
  static Future<SecretResult<void>> write(String key, String value) =>
      store.write(key, value);
  static Future<SecretResult<void>> delete(String key) => store.delete(key);
}

class Session {
  Session._();

  /// No-op: X account cookies are now synced directly inside the library store (no Keystore/Keychain encryption).
  static Future<SecretResult<void>> applyStoredCookies({
    SecretStore? store,
    void Function(String, String)? setCookies,
  }) async {
    return const SecretValue<void>(null);
  }
}
