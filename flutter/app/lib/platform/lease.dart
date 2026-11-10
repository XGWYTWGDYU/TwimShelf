import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tl_core/tl_core.dart';

import 'os.dart';
import 'system_random.dart';

/// Which window runs the app's own background work (AI tagging of new media). The apps are one
/// window each: always this one. The web build may be open in several windows at once (one
/// person's computer and phone, a few tabs): one of them holds the server's lease, renewed every
/// 15 s, and when it closes another one takes over within a minute.
class BackgroundLease extends ChangeNotifier {
  BackgroundLease._();
  static final instance = BackgroundLease._();

  bool _holder = !OS.isWeb;
  bool get holder => _holder;
  Timer? _timer;
  final String _id = List.generate(4, (_) => const SystemRandom().nextInt(0x100000000).toRadixString(16)).join();

  /// Starts asking (the web build); listeners hear when this window becomes the one or stops being it.
  Future<void> start() async {
    if (!OS.isWeb || _timer != null) return;
    await _ask();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_ask()));
  }

  Future<void> _ask() async {
    final now = await holdLease(_id).catchError((Object _) => false);
    if (now == _holder) return;
    _holder = now;
    notifyListeners();
  }
}
