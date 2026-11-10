import 'dart:js_interop';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:web/web.dart' as web;
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tl_core/tl_core.dart';

Future<Uint8List> readFileBytes(String path) async {
  final r = await http.get(Uri.base.resolve(fileUrl(path)));
  if (r.statusCode != 200) throw StateError('${r.statusCode} $path');
  return r.bodyBytes;
}

Future<bool> fileExists(String path) async => (await http.head(Uri.base.resolve(fileUrl(path)))).statusCode == 200;

/// The core makes the folders it writes to on the server.
Future<void> ensureDirectory(String path) async {}

/// An image file of the core's (on the server), for an [Image].
ImageProvider localFileImage(String path) => NetworkImage(Uri.base.resolve(fileUrl(path)).toString());

Uri _url(String path) => Uri.base.resolve(fileUrl(path));

Future<String?> readText(String path) async {
  final r = await http.get(_url(path));
  if (r.statusCode == 404) return null;
  if (r.statusCode != 200) throw StateError('${r.statusCode} $path');
  return utf8.decode(r.bodyBytes);
}

Future<void> writeText(String path, String text) async {
  final r = await http.put(_url(path), body: utf8.encode(text));
  if (r.statusCode >= 300) throw StateError('${r.statusCode} $path');
}

Future<void> movePath(String from, String to) async {
  final r = await http.post(Uri.base.resolve('api/move'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'from': from, 'to': to}));
  if (r.statusCode >= 300) throw StateError('${r.statusCode} $from');
}

Future<void> deletePath(String path) async {
  final r = await http.delete(_url(path));
  if (r.statusCode >= 300) throw StateError('${r.statusCode} $path');
}

/// A frame of a video as a JPEG on the server (square [side], or [whole] with [side] as the long
/// edge), made there with ffmpeg and cached; null when the server cannot.
Future<String?> serverPoster(String path, int side, {required bool whole}) async {
  final r = await http.get(Uri.base.resolve('api/poster').replace(queryParameters: {'path': path, 'side': '$side', 'whole': whole ? '1' : '0'}));
  if (r.statusCode != 200) return null;
  return (jsonDecode(r.body) as Map<String, dynamic>)['path'] as String?;
}

/// A picture on the server, upright and at most [side] on its long edge, as JPEG bytes; null
/// when the server cannot read it.
Future<Uint8List?> scaledImageBytes(String path, int side) async {
  final r = await http.get(Uri.base.resolve('api/scaled').replace(queryParameters: {'path': path, 'side': '$side'}));
  return r.statusCode == 200 ? r.bodyBytes : null;
}

/// A file the user picked in the browser, sent to the server (streamed by the browser, however
/// large): its path there, for the core to read.
Future<String> pickedPath(XFile file) async {
  final res = await web.window.fetch(file.path.toJS).toDart;
  final blob = await res.blob().toDart;
  final headers = web.Headers()..append('Content-Type', 'application/octet-stream');
  final up = await web.window.fetch(Uri.base.resolve('api/upload?name=${Uri.encodeQueryComponent(file.name)}').toString().toJS,
      web.RequestInit(method: 'POST', body: blob, headers: headers)).toDart;
  final text = (await up.text().toDart).toDart;
  if (up.status != 200) throw StateError('upload ${up.status}: $text');
  return (jsonDecode(text) as Map<String, dynamic>)['path'] as String;
}

/// Hands a file the core wrote on the server to the browser, which saves it (an export).
Future<void> downloadToBrowser(String path) async => downloadServerFile(path, path.split('/').last);
