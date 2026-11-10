// The apps: the core is a native library in the process, called through `dart:ffi`.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A string handed to or returned by the core: C memory here.
typedef NStr = Pointer<Utf8>;

/// Allocations of one call, freed when it returns.
typedef NArena = Arena;

T withArena<T>(T Function(Arena) action) => using(action);

NStr toNStr(String? value, Arena arena) => value == null ? nullptr : value.toNativeUtf8(allocator: arena);

bool isNullNStr(NStr p) => p == nullptr;

String readNStr(NStr p) => p.toDartString();

/// Runs [work] (calls into the core) away from the UI isolate.
Future<R> runAsync<R>(R Function() work) => Isolate.run(work);

/// The web build serves the core over HTTP: never here.
const bool coreIsRemote = false;

DynamicLibrary openCoreLibrary() {
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libtl_core.so');
  if (Platform.isWindows) return DynamicLibrary.open('tl_core.dll');
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  throw UnsupportedError('core.unsupportedPlatform');
}

CoreBindings createBindings() => CoreBindings(openCoreLibrary());
