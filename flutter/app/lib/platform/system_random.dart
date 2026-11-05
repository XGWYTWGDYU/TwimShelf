import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

/// Random numbers straight from the operating system, with no generator of the app's own in
/// between: `arc4random_buf` on Apple's systems (what Swift's `SystemRandomNumberGenerator` calls in
/// the native apps), `BCryptGenRandom` with the system's preferred generator on Windows, the
/// `getrandom` system call on Android and Linux. A call that fails throws: nothing falls back to a
/// weaker source.
class SystemRandom implements math.Random {
  const SystemRandom();

  static final void Function(Pointer<Uint8>, int) _fill = _source();

  static void Function(Pointer<Uint8>, int) _source() {
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.process().lookupFunction<Void Function(Pointer<Uint8>, Size), void Function(Pointer<Uint8>, int)>('arc4random_buf');
    }
    if (Platform.isWindows) {
      const systemPreferredRng = 2; // BCRYPT_USE_SYSTEM_PREFERRED_RNG
      final generate = DynamicLibrary.open('bcrypt.dll').lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32), int Function(Pointer<Void>, Pointer<Uint8>, int, int)>('BCryptGenRandom');
      return (buffer, length) {
        final status = generate(nullptr, buffer, length, systemPreferredRng);
        if (status != 0) throw StateError('BCryptGenRandom: $status');
      };
    }
    if (Platform.isAndroid || Platform.isLinux) {
      final getrandom = DynamicLibrary.process().lookupFunction<IntPtr Function(Pointer<Uint8>, Size, Uint32), int Function(Pointer<Uint8>, int, int)>('getrandom');
      return (buffer, length) {
        var done = 0;
        var interrupted = 0;
        while (done < length) {
          final n = getrandom(buffer + done, length - done, 0);
          if (n > 0) {
            done += n;
          } else if (++interrupted > 16) {
            // a signal can cut a large request short; this many in a row is not that
            throw StateError('getrandom: $n');
          }
        }
      };
    }
    throw UnsupportedError(Platform.operatingSystem);
  }

  /// The whole of a 64-bit integer (negative numbers too).
  int nextInt64() => using((arena) {
        final buffer = arena<Uint8>(8);
        _fill(buffer, 8);
        var v = 0;
        for (var i = 0; i < 8; i++) {
          v = (v << 8) | buffer[i];
        }
        return v;
      });

  /// Every value below [max] equally likely (drawing again rather than taking a remainder of a range
  /// that does not divide evenly). [max] is up to 2^32, as [math.Random] has it.
  @override
  int nextInt(int max) {
    if (max <= 0 || max > 0x100000000) throw RangeError.range(max, 1, 0x100000000, 'max');
    const range = 0x100000000;
    final limit = range - range % max;
    while (true) {
      final v = nextInt64() & 0xFFFFFFFF;
      if (v < limit) return v % max;
    }
  }

  @override
  double nextDouble() => ((nextInt64() >>> 11) & 0x1FFFFFFFFFFFFF) / 0x20000000000000;

  @override
  bool nextBool() => nextInt64() & 1 == 1;
}
