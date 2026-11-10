/// The web build: the app runs in a browser and the files are the server's (always "/").
abstract final class OS {
  static const bool isWeb = true;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isAndroid => false;
  static bool get isLinux => false;
  static Map<String, String> get environment => const {};
  static String get pathSeparator => '/';
  static String get resolvedExecutable => '';
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
  static int get numberOfProcessors => 4;
  static String get localHostname => 'web';
}
