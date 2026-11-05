import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../platform/secrets.dart';

/// Reserved synthetic key only; never reads or changes the user's cookies.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode) return;
  const key = 'f6.synthetic.persistence';
  const value = 'synthetic-f6-value';
  final action = Platform.environment['TL_SECRETS_SMOKE_ACTION'];
  if (action == 'write') {
    final result = await Secrets.write(key, value);
    debugPrint('secrets-smoke write=${result is SecretValue<void>}');
  } else if (action == 'read') {
    final result = await Secrets.read(key);
    debugPrint(
      'secrets-smoke persisted=${result is SecretValue<String?> && result.value == value}',
    );
  } else if (action == 'delete') {
    final result = await Secrets.delete(key);
    final read = await Secrets.read(key);
    debugPrint(
      'secrets-smoke removed=${result is SecretValue<void> && read is SecretValue<String?> && read.value == null}',
    );
  }
  runApp(const SizedBox.shrink());
}
