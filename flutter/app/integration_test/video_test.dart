import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/viewer_page.dart';

/// A video in the viewer plays, pauses and shows its controls. Run with TL_LIBRARY_DIR at a
/// synthetic library that has the seed's video.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(WidgetTester t, bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a video plays and pauses in the viewer', (tester) async {
    await L10n.load();
    await Prefs.load();
    final library = await LibraryModel.open();
    final videos = await library.feed(FeedRequest(filter: Place.videos.filter));
    expect(videos, isNotEmpty, reason: 'the seed needs ffmpeg for its video');
    await tester.pumpWidget(MaterialApp(home: ViewerPage(library: library, items: videos, index: 0)));
    final play = find.byKey(const ValueKey('videoPlay'));
    await until(tester, () => play.evaluate().isNotEmpty && find.byTooltip(L('viewer.pause')).evaluate().isNotEmpty);
    expect(find.byTooltip(L('viewer.pause')), findsOneWidget);
    expect(find.byKey(const ValueKey('videoMute')), findsOneWidget);
    await tester.tap(play);
    await until(tester, () => find.byTooltip(L('viewer.play')).evaluate().isNotEmpty);
    expect(find.byTooltip(L('viewer.play')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
