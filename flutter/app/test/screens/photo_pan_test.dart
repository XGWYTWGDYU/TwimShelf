import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/screens/viewer_page.dart';

void main() {
  testWidgets('double tap zoom allows a one-finger vertical pan', (t) async {
    final item = FeedItem(media_id: 'photo', post_id: 'post', ordinal: 0,
        kind: MediaKind.photo, path: '/synthetic/missing-photo');
    await t.pumpWidget(MaterialApp(home: ViewerPage(
      library: LibraryModel.forTest('/synthetic/unused'), items: [item], index: 0)));
    await t.pump();
    final viewer = find.byType(InteractiveViewer);
    await t.tapAt(const Offset(400, 250));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(const Offset(400, 250));
    await t.pumpAndSettle();
    final transform = t.widget<InteractiveViewer>(viewer).transformationController!;
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    final before = transform.value.getTranslation().y;
    await t.dragFrom(const Offset(400, 250), const Offset(0, 90));
    await t.pumpAndSettle();
    expect(transform.value.getTranslation().y, greaterThan(before + 20));
    expect(find.byType(ViewerPage), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
