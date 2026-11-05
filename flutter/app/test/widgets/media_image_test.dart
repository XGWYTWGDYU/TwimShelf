import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/widgets/media_image.dart';

void main() {
  test('HEIC and AVIF go through the core, whatever the case; others stay Flutter\'s', () {
    for (final p in ['a.heic', 'b.HEIC', 'c.heif', 'd.hif', 'e.avif', '/x.y/f.AvIf']) {
      expect(isHeifPath(p), isTrue, reason: p);
    }
    for (final p in ['a.jpg', 'b.png', 'c.webp', 'heic', '/x.heic/y', 'z']) {
      expect(isHeifPath(p), isFalse, reason: p);
    }
  });

  test('the same file at the same size is the same image in the cache', () {
    expect(const HeifFileImage('a.heic', 2048), const HeifFileImage('a.heic', 2048));
    expect(const HeifFileImage('a.heic', 2048) == const HeifFileImage('a.heic', 4096), isFalse);
    expect(mediaImage('a.jpg', cacheWidth: 100, maxSide: 2048), isA<ResizeImage>());
  });
}
