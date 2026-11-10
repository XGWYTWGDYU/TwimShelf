import 'dart:math' as math;

/// The browser's cryptographic random numbers (`Random.secure` is `crypto.getRandomValues`). A web
/// number has 53 bits: [nextInt64] gives 53 random bits. (No shifts by 32 here: a JavaScript
/// shift works on 32 bits.)
class SystemRandom implements math.Random {
  const SystemRandom();
  static final _r = math.Random.secure();
  static const _two32 = 4294967296;
  static const _two21 = 2097152;
  static const _two16 = 65536;

  int nextInt64() => _r.nextInt(_two32) * _two21 + _r.nextInt(_two21);

  @override
  int nextInt(int max) {
    if (max <= 0 || max > _two32) throw RangeError.range(max, 1, _two32, 'max');
    if (max <= _two32 ~/ 2) return _r.nextInt(max);
    // above 2^31: from 48 random bits, nearly unbiased for any max up to 2^32
    return ((_r.nextInt(_two16) * _two32) + _r.nextInt(_two32)) % max;
  }

  @override
  double nextDouble() => _r.nextDouble();

  @override
  bool nextBool() => _r.nextBool();
}
