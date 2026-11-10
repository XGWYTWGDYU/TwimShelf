import 'dart:async';

abstract interface class HeadphoneRoutes {
  Future<bool> current();
  Stream<bool> get changes;
  Future<void> dispose();
}

/// A page cannot see the audio route: always "speakers", so a video starts muted and asks first,
/// as on a device without headphones.
class SystemHeadphoneRoutes implements HeadphoneRoutes {
  @override
  Future<bool> current() async => false;
  @override
  Stream<bool> get changes => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

bool isPrivateLinuxOutput(Map<String, dynamic> sink) => false;
