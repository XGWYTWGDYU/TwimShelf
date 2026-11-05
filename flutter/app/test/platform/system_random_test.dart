import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/platform/system_random.dart';

void main() {
  const random = SystemRandom();

  test('the system source answers, and differently each time', () {
    final draws = {for (var i = 0; i < 1000; i++) random.nextInt64()};
    expect(draws.length, 1000);
    expect(draws.any((v) => v < 0), isTrue, reason: 'all 64 bits are drawn');
  });

  test('nextInt stays in range and reaches all of it; bad ranges are refused', () {
    final seen = <int>{};
    for (var i = 0; i < 2000; i++) {
      final v = random.nextInt(6);
      expect(v, inInclusiveRange(0, 5));
      seen.add(v);
    }
    expect(seen.length, 6);
    expect(random.nextInt(1 << 32), inInclusiveRange(0, 0xFFFFFFFF));
    expect(() => random.nextInt(0), throwsRangeError);
    expect(() => random.nextInt((1 << 32) + 1), throwsRangeError);
  });

  test('nextDouble is in [0, 1) and nextBool gives both', () {
    final bools = <bool>{};
    for (var i = 0; i < 1000; i++) {
      final d = random.nextDouble();
      expect(d >= 0 && d < 1, isTrue);
      bools.add(random.nextBool());
    }
    expect(bools.length, 2);
  });
}
