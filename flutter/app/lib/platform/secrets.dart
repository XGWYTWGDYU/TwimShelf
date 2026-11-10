import 'dart:convert';


import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'os.dart';
import 'files.dart' as files;

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

/// Windows and Linux: the app keeps its secrets itself, in the data folder (`App/secrets.json`),
/// each value sealed (ChaCha20-Poly1305, by the core) under a key beside it (`App/secrets.key`).
/// Not real protection — any program that can read the folder can open them — but they are
/// never plain text, they move with the data folder, and no system keyring is needed (Linux has
/// none that every desktop provides, and Windows' DPAPI protects nothing from other programs).
class DataFolderSecretBackend implements SecretBackend {
  DataFolderSecretBackend(this.directory);
  final Future<String> Function() directory;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _tail.then((_) => f());
    _tail = r.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return r;
  }

  // (through files.dart: the data folder on this device, or the server's in the web build)
  Future<(String, String)> _open() async {
    final dir = await directory();
    await files.ensureDirectory(dir);
    final keyPath = '$dir${OS.pathSeparator}secrets.key';
    var key = await files.readText(keyPath);
    if (key == null) {
      key = Core.secretKey();
      await files.writeText(keyPath, key);
    }
    return ('$dir${OS.pathSeparator}secrets.json', key.trim());
  }

  Future<Map<String, dynamic>> _read(String f) async {
    final text = await files.readText(f);
    if (text == null) return {};
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      // damaged: kept aside, never silently dropped (the app reports secrets as unavailable)
      await files.movePath(f, '$f.damaged-${DateTime.now().millisecondsSinceEpoch}');
      throw const _Unavailable();
    }
  }

  Future<void> _write(String f, Map<String, dynamic> m) => files.writeText(f, jsonEncode(m));

  @override
  Future<String?> read(String key) => _serial(() async {
        final (f, k) = await _open();
        final blob = (await _read(f))[key] as String?;
        return blob == null ? null : Core.secretOpen(k, blob);
      });

  @override
  Future<void> write(String key, String value) => _serial(() async {
        final (f, k) = await _open();
        final m = await _read(f);
        m[key] = Core.secretSeal(k, value);
        await _write(f, m);
      });

  @override
  Future<void> delete(String key) => _serial(() async {
        final (f, _) = await _open();
        final m = await _read(f);
        if (m.remove(key) != null) await _write(f, m);
      });
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

class _Unavailable implements Exception {
  const _Unavailable();
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
      // Windows, Linux: in the data folder; Apple: Keychain; Android: Keystore
      // the web build: on the server, beside the library (the server itself syncs with them)
      : OS.isWindows || OS.isLinux || OS.isWeb
          ? DataFolderSecretBackend(() async => (await getApplicationSupportDirectory()).path)
          : PlatformSecretBackend());
  static Future<SecretResult<String?>> read(String key) => store.read(key);
  static Future<SecretResult<void>> write(String key, String value) =>
      store.write(key, value);
  static Future<SecretResult<void>> delete(String key) => store.delete(key);
}

class Session {
  Session._();

  /// Call after Core.open at launch. Missing cookies become empty strings;
  /// unavailable storage clears any stale in-memory pair and reports failure.
  static Future<SecretResult<void>> applyStoredCookies({
    SecretStore? store,
    void Function(String, String)? setCookies,
  }) async {
    final source = store ?? Secrets.store;
    final apply = setCookies ?? Core.setCookies;
    final auth = await source.read('auth_token');
    final csrf = await source.read('ct0');
    if (auth is! SecretValue<String?> || csrf is! SecretValue<String?>) {
      apply('', '');
      return const SecretsUnavailable<void>();
    }
    apply(auth.value ?? '', csrf.value ?? '');
    return const SecretValue<void>(null);
  }
}
