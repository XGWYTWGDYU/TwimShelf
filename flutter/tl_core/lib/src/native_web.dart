// The web build: the core runs on the TwimShelf server, each call one HTTP request.
import 'bindings_web.dart';
import 'web_transport.dart' as transport;

/// A string handed to or returned by the core: a Dart string here (nothing to free).
typedef NStr = String?;

typedef NArena = Object?;

T withArena<T>(T Function(Object?) action) => action(null);

NStr toNStr(String? value, Object? arena) => value;

bool isNullNStr(NStr p) => p == null;

String readNStr(NStr p) => p!;

/// Runs [work] without blocking the page: its calls to the core go out as asynchronous requests.
Future<R> runAsync<R>(R Function() work) => transport.runAsync(work);

const bool coreIsRemote = true;

CoreBindings createBindings() => CoreBindings();
