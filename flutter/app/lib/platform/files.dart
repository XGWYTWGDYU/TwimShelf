// Reading the core's files: from the disk in the apps, from the server (`/f/…`) in the web build.
export 'files_io.dart' if (dart.library.js_interop) 'files_web.dart';
