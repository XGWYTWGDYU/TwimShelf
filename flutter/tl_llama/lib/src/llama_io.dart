import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// llama.cpp for the Flutter app on Android, Windows and Linux (the Apple builds run MLX).
///
/// One job at a time, off the UI isolate; a model stays loaded between the pictures of a batch
/// and goes 30 s after the last job, as the MLX engine does.
class LlamaEngine {
  LlamaEngine._();
  static final instance = LlamaEngine._();

  static bool get isSupported => Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  String? _backendsDir;
  String? devices;
  _Loaded? _tagger;
  Future<void> _tail = Future.value();
  Timer? _idle;

  /// Loads the backends (CPU, and Vulkan where a driver exists) from [backendsDir]: Android's
  /// native library folder; null on desktops (next to the program). Returns the devices found.
  Future<String> init(String? backendsDir) async {
    _backendsDir = backendsDir;
    final known = devices;
    if (known != null) return known;
    final String found = await Isolate.run<String>(() => _Native.init(backendsDir));
    devices = found;
    return found;
  }

  Future<T> _exclusive<T>(Future<T> Function() body) {
    _idle?.cancel();
    final r = _tail.then((_) => body());
    _tail = r.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    r.whenComplete(() {
      _idle?.cancel();
      _idle = Timer(const Duration(seconds: 30), () => unloadAll());
    }).ignore();
    return r;
  }

  /// Tags' raw answer for the picture at [image] (JPEG / PNG) from a vision model.
  Future<String> describe({required String weights, required String projector, required String image, required String system, required String question, int maxTokens = 160, int gpuLayers = 999}) =>
      _exclusive(() async {
        final key = '$weights|$projector';
        if (_tagger?.key != key) {
          await _free(_tagger);
          _tagger = null;
          _tagger = _Loaded(key, await _loadOffThread(_backendsDir, weights, projector, gpuLayers));
        }
        return _describeOffThread(_tagger!.address, image, system, question, maxTokens);
      });

  /// A model's answer as text. One stopped at its token limit, or a token that is half a character,
  /// can end inside a character; what is whole is kept.
  static String decodeAnswer(List<int> bytes) => utf8.decode(bytes, allowMalformed: true).replaceAll('\uFFFD', '');

  // Static: a closure made inside `describe` would take the engine with it, and its timer cannot
  // cross to another isolate.
  static Future<int> _loadOffThread(String? dir, String weights, String projector, int gpuLayers) =>
      Isolate.run(() => _Native.load(dir, weights, projector, gpuLayers, 4096, false));
  static Future<String> _describeOffThread(int address, String image, String system, String question, int maxTokens) =>
      Isolate.run(() => _Native.describe(address, image, system, question, maxTokens));

  Future<void> unloadAll() => _exclusive(() async {
        await _free(_tagger);
        _tagger = null;
      });

  static Future<void> _free(_Loaded? l) async {
    if (l == null) return;
    final a = l.address;
    await Isolate.run(() => _Native.unload(a));
  }
}

class _Loaded {
  _Loaded(this.key, this.address);
  final String key;
  final int address;
}

/// The C interface (src/tl_llama.h), used inside worker isolates; handles cross as addresses.
class _Native {
  static final DynamicLibrary _lib = Platform.isWindows
      ? DynamicLibrary.open('tl_llama.dll')
      : DynamicLibrary.open('libtl_llama.so');

  static final _init = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('tl_llama_init');
  static final _load = _lib.lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32, Pointer<Pointer<Utf8>>),
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int, int, int, Pointer<Pointer<Utf8>>)>('tl_llama_load');
  static final _describe = _lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Pointer<Utf8>>),
      Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<Utf8>>)>('tl_llama_describe');
  static final _unload = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('tl_llama_unload');
  static final _freeString = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('tl_llama_free_string');

  // every worker isolate is new but the process is the same: the C side loads the backends
  // once and answers later calls from what it found
  static void _ensure(String? dir) => init(dir);

  static String init(String? dir) => using((a) {
        final p = _init(dir == null ? nullptr : dir.toNativeUtf8(allocator: a));
        return _take(p) ?? '';
      });

  static String? _take(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    final s = LlamaEngine.decodeAnswer(p.cast<Uint8>().asTypedList(p.length));
    _freeString(p);
    return s;
  }

  static Never _fail(Pointer<Pointer<Utf8>> error, String what) => throw LlamaException('$what: ${_take(error.value) ?? '?'}');

  static int load(String? dir, String weights, String? projector, int gpuLayers, int context, bool embeddings) => using((a) {
        _ensure(dir);
        final err = a<Pointer<Utf8>>()..value = nullptr;
        final m = _load(weights.toNativeUtf8(allocator: a), projector == null ? nullptr : projector.toNativeUtf8(allocator: a), gpuLayers, context,
            embeddings ? 1 : 0, err);
        if (m == nullptr) _fail(err, 'load');
        return m.address;
      });

  static String describe(int address, String image, String system, String question, int maxTokens) => using((a) {
        final err = a<Pointer<Utf8>>()..value = nullptr;
        final out = _describe(Pointer<Void>.fromAddress(address), image.toNativeUtf8(allocator: a), system.toNativeUtf8(allocator: a),
            question.toNativeUtf8(allocator: a), maxTokens, err);
        return _take(out) ?? _fail(err, 'describe');
      });


  static void unload(int address) => _unload(Pointer<Void>.fromAddress(address));
}

class LlamaException implements Exception {
  LlamaException(this.message);
  final String message;
  @override
  String toString() => message;
}
