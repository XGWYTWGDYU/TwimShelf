// The apps reach the core in the process: there is no server (these are never called there).
import 'dart:typed_data';

class RemoteCoreError implements Exception {
  const RemoteCoreError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class ServerInfo {
  ServerInfo(this.json);
  final Map<String, dynamic> json;
  String get data => json['data'] as String;
  String get library => json['library'] as String;
  String get models => json['models'] as String;
  String get cache => json['cache'] as String;
  String get uploads => json['uploads'] as String;
  String get exports => json['exports'] as String;
  String get version => json['version'] as String? ?? '';
}

ServerInfo get serverInfo => throw UnsupportedError('no server');
Future<ServerInfo> loadServerInfo() => throw UnsupportedError('no server');
String fileUrl(String path) => path;
Future<String> uploadBytes(String name, Uint8List bytes) => throw UnsupportedError('no server');
Future<({int status, Map<String, String> headers, Uint8List body})> proxyRequest(String method, Uri url,
        {Map<String, String> headers = const {}, List<int>? body}) =>
    throw UnsupportedError('no server');
void downloadServerFile(String path, String name) => throw UnsupportedError('no server');
void signOut() {}
void signedOut() {}
/// The apps are one window: theirs is the background work.
Future<bool> holdLease(String id) async => true;
