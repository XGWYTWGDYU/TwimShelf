// How `Core` reaches the Rust core: through FFI in the apps, over HTTP in the web build.
export 'native_io.dart' if (dart.library.js_interop) 'native_web.dart';
