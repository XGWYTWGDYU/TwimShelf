import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tl_core/tl_core.dart';

/// The web build: the app's folders are the server's (the core reads and writes them there).
/// Support files go to `<data>/app`, caches to `<data>/cache`, scratch and exports to
/// `<data>/exports` (from where the browser downloads them).
class ServerPaths extends PathProviderPlatform {
  ServerPaths(this.info);
  final ServerInfo info;

  @override
  Future<String?> getApplicationSupportPath() async => '${info.data}/app';
  @override
  Future<String?> getApplicationDocumentsPath() async => '${info.data}/app';
  @override
  Future<String?> getApplicationCachePath() async => info.cache;
  @override
  Future<String?> getLibraryPath() async => '${info.data}/app';
  @override
  Future<String?> getTemporaryPath() async => info.exports;
  @override
  Future<String?> getDownloadsPath() async => info.exports;
  @override
  Future<String?> getExternalStoragePath() async => null;
  @override
  Future<List<String>?> getExternalCachePaths() async => null;
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => null;
}
