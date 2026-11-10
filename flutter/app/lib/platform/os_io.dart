import 'dart:io' as io;

abstract final class OS {
  static const bool isWeb = false;
  static bool get isIOS => io.Platform.isIOS;
  static bool get isMacOS => io.Platform.isMacOS;
  static bool get isWindows => io.Platform.isWindows;
  static bool get isAndroid => io.Platform.isAndroid;
  static bool get isLinux => io.Platform.isLinux;
  static Map<String, String> get environment => io.Platform.environment;
  static String get pathSeparator => io.Platform.pathSeparator;
  static String get resolvedExecutable => io.Platform.resolvedExecutable;
  static String get operatingSystem => io.Platform.operatingSystem;
  static String get operatingSystemVersion => io.Platform.operatingSystemVersion;
  static int get numberOfProcessors => io.Platform.numberOfProcessors;
  static String get localHostname => io.Platform.localHostname;
}
