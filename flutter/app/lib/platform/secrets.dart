import 'dart:convert';
import 'dart:io';


import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

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

  Future<(File, String)> _open() async {
    final dir = await directory();
    await Directory(dir).create(recursive: true);
    final keyFile = File('$dir${Platform.pathSeparator}secrets.key');
    if (!await keyFile.exists()) await keyFile.writeAsString(Core.secretKey(), flush: true);
    return (File('$dir${Platform.pathSeparator}secrets.json'), (await keyFile.readAsString()).trim());
  }

  Future<Map<String, dynamic>> _read(File f) async {
    if (!await f.exists()) return {};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // damaged: kept aside, never silently dropped (the app reports secrets as unavailable)
      await f.rename('${f.path}.damaged-${DateTime.now().millisecondsSinceEpoch}');
      throw const _Unavailable();
    }
  }

  Future<void> _write(File f, Map<String, dynamic> m) async {
    final tmp = File('${f.path}.partial');
    await tmp.writeAsString(jsonEncode(m), flush: true);
    await tmp.rename(f.path);
  }

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
  static final SecretStore store = SecretStore(kDebugMode && Platform.environment['TL_LIBRARY_DIR'] != null
      ? MemorySecretBackend()
      // Windows, Linux: in the data folder; Apple: Keychain; Android: Keystore
      : Platform.isWindows || Platform.isLinux
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
