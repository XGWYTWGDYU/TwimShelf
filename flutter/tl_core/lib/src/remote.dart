// The server, for the web build (files, uploads, requests through it); the apps have none.
export 'remote_io.dart' if (dart.library.js_interop) 'web_transport.dart'
    show RemoteCoreError, ServerInfo, serverInfo, loadServerInfo, fileUrl, uploadBytes, proxyRequest, downloadServerFile, signOut, signedOut, holdLease;
