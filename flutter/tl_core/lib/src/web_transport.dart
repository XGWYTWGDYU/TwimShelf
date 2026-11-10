// The web build's way to the core: HTTP requests to the TwimShelf server (server/src/main.rs),
// same origin. One function call = `POST /api/call/<name>` with the arguments as a JSON array;
// the answer is `{"r": <result>}` (the result as the C function returns it).
//
// The core's functions are synchronous, and so is `Core`. A quick call therefore goes out as a
// synchronous request (on a home network a few milliseconds). Work that may take long runs in
// `runAsync` (`Isolate.run` in the apps): there every call is made as an asynchronous request
// instead — the work is run, its first call that has no answer yet stops it, that call is made
// (without blocking the page), and the work runs again from the start with the answers so far,
// until it completes. The work between calls is plain decoding, so running it again is harmless.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// What the server answered instead of a result.
class RemoteCoreError implements Exception {
  const RemoteCoreError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// A call inside `runAsync` that has no answer yet (an Error, so that `on Exception` handlers in
/// the work let it through).
class _Pending extends Error {
  _Pending(this.name, this.body, this.key);
  final String name, body, key;
}

class _Replay {
  final answers = <String, List<Object?>>{};
  final seen = <String, int>{};
  /// The first call of this run with no answer yet — kept here too, because work with a
  /// catch-all handler may swallow the thrown [_Pending] and return as if it had failed.
  _Pending? pending;
}

const _replayKey = #tlCoreReplay;

Object? coreCall(String name, List<Object?> args) {
  final body = jsonEncode(args);
  final replay = Zone.current[_replayKey] as _Replay?;
  if (replay == null) return _postSync(name, body);
  final key = '$name\u0000$body';
  final n = replay.seen[key] = (replay.seen[key] ?? -1) + 1;
  final got = replay.answers[key];
  if (got != null && n < got.length) return got[n];
  throw replay.pending ??= _Pending(name, body, key);
}

Future<R> runAsync<R>(R Function() work) async {
  final replay = _Replay();
  while (true) {
    replay.seen.clear();
    replay.pending = null;
    try {
      final result = runZoned(work, zoneValues: {_replayKey: replay});
      // a call went unanswered even though the work returned: its result is not the real one
      if (replay.pending == null) return result;
    } on _Pending {
      // made below
    } catch (_) {
      // an error thrown only because a call had no answer yet: run again with it
      if (replay.pending == null) rethrow;
    }
    final p = replay.pending!;
    (replay.answers[p.key] ??= []).add(await _post(p.name, p.body));
  }
}

Object? _decode(int status, String text) {
  if (status == 200) return (jsonDecode(text) as Map<String, dynamic>)['r'];
  if (status == 401) {
    // signed out (the password was changed, the sign-in ran out): the page goes to the sign-in
    signedOut();
    throw const RemoteCoreError(401, 'server.unauthorized');
  }
  if (status == 0) throw const RemoteCoreError(0, 'server.unreachable');
  throw RemoteCoreError(status, text.isEmpty ? 'server.error' : text);
}

Object? _postSync(String name, String body) {
  final x = web.XMLHttpRequest();
  x.open('POST', 'api/call/$name', false);
  x.setRequestHeader('Content-Type', 'application/json');
  try {
    x.send(body.toJS);
  } catch (_) {
    throw const RemoteCoreError(0, 'server.unreachable');
  }
  return _decode(x.status, x.responseText);
}

Future<Object?> _post(String name, String body) async {
  final res = await _fetch('api/call/$name', 'POST', body.toJS, 'application/json');
  return _decode(res.$1, res.$2);
}

var _leaving = false;

/// To the server's sign-in page (once), coming back here afterwards.
void signedOut() {
  if (_leaving) return;
  _leaving = true;
  final here = web.window.location;
  here.assign('login?next=${Uri.encodeComponent(here.pathname)}');
}

/// Signs this browser out (the server forgets nothing else: the library stays as it is).
void signOut() => web.window.location.assign('logout');

/// Whether this window runs the web app's own background work (AI tagging, handing queued
/// downloads on): one window at a time, see the server's `/api/lease`.
Future<bool> holdLease(String id) async {
  final r = await _fetch('api/lease', 'POST', jsonEncode({'id': id}).toJS, 'application/json');
  if (r.$1 == 401) signedOut();
  if (r.$1 != 200) return false;
  return (jsonDecode(r.$2) as Map<String, dynamic>)['holder'] == true;
}

Future<(int, String)> _fetch(String url, String method, JSAny? body, String? type) async {
  final headers = web.Headers();
  if (type != null) headers.append('Content-Type', type);
  try {
    final res = await web.window.fetch(url.toJS, web.RequestInit(method: method, body: body, headers: headers)).toDart;
    return (res.status, (await res.text().toDart).toDart);
  } catch (_) {
    return (0, '');
  }
}

/// Where the server keeps the data (its paths, for the core's arguments).
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

ServerInfo? _info;
ServerInfo get serverInfo => _info ?? (throw StateError('loadServerInfo first'));

Future<ServerInfo> loadServerInfo() async {
  final r = await _fetch('api/info', 'GET', null, null);
  if (r.$1 == 401) signedOut();
  if (r.$1 != 200) throw RemoteCoreError(r.$1, r.$2);
  return _info = ServerInfo(jsonDecode(r.$2) as Map<String, dynamic>);
}

/// The address of a file on the server (a path the core gave), for images and videos.
String fileUrl(String path) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  return 'f/${p.split('/').map(Uri.encodeComponent).join('/')}';
}

/// Sends a file of the browser to the server; its path there.
Future<String> uploadBytes(String name, Uint8List bytes) async {
  final r = await _fetch('api/upload?name=${Uri.encodeQueryComponent(name)}', 'POST', bytes.toJS, 'application/octet-stream');
  if (r.$1 != 200) throw RemoteCoreError(r.$1, r.$2);
  return (jsonDecode(r.$2) as Map<String, dynamic>)['path'] as String;
}

/// Sends a browser file (a `File`/`Blob`, streamed by the browser) to the server; its path there.
Future<String> uploadBlob(String name, web.Blob blob) async {
  final r = await _fetch('api/upload?name=${Uri.encodeQueryComponent(name)}', 'POST', blob, 'application/octet-stream');
  if (r.$1 != 200) throw RemoteCoreError(r.$1, r.$2);
  return (jsonDecode(r.$2) as Map<String, dynamic>)['path'] as String;
}

/// An HTTP request made by the server on the page's behalf (other origins refuse a page).
Future<({int status, Map<String, String> headers, Uint8List body})> proxyRequest(String method, Uri url,
    {Map<String, String> headers = const {}, List<int>? body}) async {
  final req = jsonEncode({
    'url': url.toString(),
    'method': method,
    'headers': [for (final e in headers.entries) [e.key, e.value]],
    'body': body == null ? null : base64Encode(body),
  });
  final r = await _fetch('api/proxy', 'POST', req.toJS, 'application/json');
  if (r.$1 != 200) throw RemoteCoreError(r.$1, r.$2);
  final j = jsonDecode(r.$2) as Map<String, dynamic>;
  return (
    status: (j['status'] as num).toInt(),
    headers: {for (final h in (j['headers'] as List)) (h as List)[0] as String: h[1] as String},
    body: base64Decode(j['body'] as String),
  );
}

/// Hands the browser a file of the server to save (an export).
void downloadServerFile(String path, String name) {
  final a = web.HTMLAnchorElement()
    ..href = fileUrl(path)
    ..download = name;
  web.document.body?.append(a);
  a.click();
  a.remove();
}
