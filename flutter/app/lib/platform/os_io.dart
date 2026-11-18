import 'dart:io' as io;

abstract final class OS {
  static bool get isIOS => io.Platform.isIOS;
  static bool get isAndroid => io.Platform.isAndroid;
  static Map<String, String> get environment => io.Platform.environment;
  static String get pathSeparator => io.Platform.pathSeparator;
  static String get resolvedExecutable => io.Platform.resolvedExecutable;
  static String get operatingSystem => io.Platform.operatingSystem;
  static String get operatingSystemVersion => io.Platform.operatingSystemVersion;
  static int get numberOfProcessors => io.Platform.numberOfProcessors;
  static String get localHostname => io.Platform.localHostname;
}
