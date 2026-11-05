import 'package:test/test.dart';
import 'package:tl_core/tl_core.dart';

void main() {
  test('cached JPEG result round trips with an immutable path', () {
    final result = ThumbnailResult.fromJson({'path': '/cache/384/media.jpg'});
    expect(result, isA<ThumbnailImage>());
    expect((result as ThumbnailImage).path, '/cache/384/media.jpg');
    expect(result.toJson(), {'path': '/cache/384/media.jpg'});
  });
  test('video result is distinct and round trips', () {
    final result = ThumbnailResult.fromJson({'video': true});
    expect(result, isA<ThumbnailVideo>());
    expect(result.toJson(), {'video': true});
  });
  test('malformed results cannot become image paths', () {
    for (final json in <Map<String, dynamic>>[
      {},
      {'video': false},
      {'path': 7},
      {'path': ''}
    ]) {
      expect(() => ThumbnailResult.fromJson(json), throwsFormatException);
    }
  });
}
