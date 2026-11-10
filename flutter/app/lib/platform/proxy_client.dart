import 'package:http/http.dart' as http;
import 'package:tl_core/tl_core.dart';

/// The web build's HTTP client for other sites (external AI services): a page may not call
/// them itself across origins, so the server makes each request on its behalf (`/api/proxy`).
/// The answer comes whole, not streamed.
class ProxyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final r = await proxyRequest(request.method, request.url, headers: request.headers, body: body.isEmpty ? null : body);
    return http.StreamedResponse(
      Stream.value(r.body),
      r.status,
      contentLength: r.body.length,
      request: request,
      headers: {for (final e in r.headers.entries) e.key.toLowerCase(): e.value},
    );
  }
}

/// The client for other sites: direct in the apps, through the server on the web.
http.Client externalClient() => coreIsRemote ? ProxyClient() : http.Client();
