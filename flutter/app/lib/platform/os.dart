// The operating system the app runs on: `dart:io`'s Platform in the apps; in the web build every
// "is…" is false (the page's own platform is not the server's).
export 'os_io.dart' if (dart.library.js_interop) 'os_web.dart';
