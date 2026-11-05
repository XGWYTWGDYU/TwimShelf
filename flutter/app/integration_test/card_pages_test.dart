import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/app/shell.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/browse_page.dart';
import 'package:twimshelf/widgets/choice_menu.dart';
import 'package:twimshelf/screens/folders_page.dart';
import 'package:twimshelf/screens/grid_page.dart';
import 'package:twimshelf/grid/thumb_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A card follows the page it shows, frame by frame, on a narrow and on a wide window, with the
/// core and a synthetic post of pictures of different shapes.
///   flutter test integration_test/card_pages_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('narrow and wide: the height moves through the pages, the card below moves along', (t) async {
    late List<FeedItem> items;
    late LibraryModel library;
    await t.runAsync(() async {
      await L10n.load(locale: const Locale('zh', 'CN'));
      SharedPreferences.setMockInitialValues({});
      await Prefs.load();
      final base = await Directory('${(await getTemporaryDirectory()).path}/tl-cards-$pid').create(recursive: true);
      final post = await Directory('${base.path}/in/多比例').create(recursive: true);
      final other = await Directory('${base.path}/in/另一帖').create(recursive: true);
      Future<void> png(Directory d, String name, int w, int h) => File('${d.path}/$name').writeAsBytes(img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(w % 255, 120, h % 255))));
      await png(post, '1.png', 800, 800);
      await png(post, '2.png', 1000, 500);
      await png(post, '3.png', 500, 900);
      await png(other, '1.png', 800, 600);
      expect(Core.open('${base.path}/lib'), isTrue);
      await Core.importLegacyDirectoryAsync('${base.path}/in');
      items = Core.feed(FeedRequest(fuzzy: false));
      library = LibraryModel.forTest('${base.path}/lib');
    });
    final byPost = <String, List<FeedItem>>{};
    for (final i in items) {
      (byPost[i.post_id] ??= []).add(i);
    }
    final pages = byPost.values.firstWhere((m) => m.length == 3)..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    expect([for (final i in pages) i.width * 10 ~/ i.height], [10, 20, 5], reason: 'the sizes reached the feed');
    final under = byPost.values.firstWhere((m) => m.length == 1);

    for (final (size, columns) in [(const Size(420, 900), 1), (const Size(1400, 900), 3)]) {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MasonryGridView.count(
            crossAxisCount: columns,
            itemCount: columns == 1 ? 2 : 2,
            itemBuilder: (context, i) => i == 0
                ? PostCard(key: ValueKey('card$size'), library: library, media: pages, onOpen: (_) {})
                : PostCard(key: ValueKey('under$size'), library: library, media: under, onOpen: (_) {}),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 100));
      final card = find.byKey(ValueKey('card$size'));
      final width = t.getSize(card).width;
      final caption = t.getSize(card).height - width;
      final bottomOfUnder = t.getBottomLeft(find.byKey(ValueKey('under$size'))).dy;

      Future<void> turn(Key button, double want) async {
        await t.tap(find.byKey(button).first);
        final heights = <double>[];
        for (var i = 0; i < 30; i++) {
          await t.pump(const Duration(milliseconds: 16));
          heights.add(t.getSize(card).height);
        }
        await t.pump(const Duration(milliseconds: 300));
        expect(t.getSize(card).height, closeTo(caption + want, 1.5));
        final steps = heights.toSet().length;
        // a busy machine draws fewer frames: still more than one jump
        expect(steps, greaterThan(2), reason: 'it moves through heights in between, not in one jump ($size)');
      }

      await turn(const ValueKey('cardNext'), width / 2);
      if (columns == 1) expect(t.getBottomLeft(find.byKey(ValueKey('under$size'))).dy, lessThan(bottomOfUnder), reason: 'the card under it came up');
      await turn(const ValueKey('cardNext'), width * 1.8);
      await turn(const ValueKey('cardPrev'), width / 2);
    }
    t.view.reset();
  });

  testWidgets('a picture of the floating bar over a page', (t) async {
    t.view.physicalSize = const Size(780, 1400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
        home: Scaffold(
          extendBody: true,
          body: ListView(children: [for (var i = 0; i < 12; i++) Padding(padding: const EdgeInsets.all(8), child: Card.filled(child: SizedBox(height: 140, child: Center(child: Text('$i')))))]),
          bottomNavigationBar: FloatingNavBar(places: Place.primary, current: Place.browse, onTap: (_) {}),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final picture = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      final out = File('${(await getTemporaryDirectory()).path}/floating-bar.png');
      await out.writeAsBytes(png!.buffer.asUint8List());
      debugPrint('PICTURE ${out.path}');
    });
  });

  testWidgets('pictures of the floating search bar and the folders page, at a phone\'s width', (t) async {
    t.view.physicalSize = const Size(780, 1500);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final library = LibraryModel.forTest('unused');
    await t.runAsync(() async {
      Core.createFolder('猫猫');
      Core.createFolder('风景');
      library.folders = Core.folderOverview();
    });
    Future<void> picture(String name, Widget page) async {
      final key = GlobalKey();
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
          home: Scaffold(
            extendBody: true,
            body: page,
            bottomNavigationBar: FloatingNavBar(places: Place.primary, current: Place.browse, onTap: (_) {}),
          ),
        ),
      ));
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = File('${(await getTemporaryDirectory()).path}/$name.png');
        await out.writeAsBytes(png!.buffer.asUint8List());
        debugPrint('PICTURE ${out.path}');
      });
    }

    await picture('floating-search', MediaQuery(data: MediaQueryData(size: const Size(390, 750), padding: const EdgeInsets.only(top: 44)), child: BrowsePage(library: library)));
    expect(find.byKey(const ValueKey('floatingSearch')), findsOneWidget);
    await picture('folders-page', FoldersPage(library: library, onOpen: (_) {}));
    expect(find.byKey(const ValueKey('folder-猫猫')), findsOneWidget);
  });

  testWidgets('frames of the appearance menu opening and closing', (t) async {
    t.view.physicalSize = const Size(780, 500);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    var value = 0;
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (c, set) => ListTile(
              title: const Text('外观'),
              trailing: ChoiceMenu<int>(
                key: const ValueKey('menu'),
                value: value,
                items: const [(0, '跟随系统'), (1, '浅色'), (2, '深色')],
                onChanged: (v) => set(() => value = v),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    final frames = <img.Image>[];
    final dir = (await getTemporaryDirectory()).path;
    Future<void> shot() async {
      await t.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 0.5);
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        frames.add(img.Image.fromBytes(width: image.width, height: image.height, bytes: raw!.buffer, numChannels: 4));
      });
    }

    await t.tap(find.byKey(const ValueKey('menu')));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 15));
      await shot();
    }
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.text('深色').last);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 15));
      await shot();
    }
    final w = frames.first.width, h = frames.first.height;
    const perRow = 5;
    final sheet = img.Image(width: (w + 6) * perRow, height: (h + 6) * ((frames.length + perRow - 1) ~/ perRow));
    img.fill(sheet, color: img.ColorRgb8(255, 0, 255));
    for (var i = 0; i < frames.length; i++) {
      img.compositeImage(sheet, frames[i], dstX: (i % perRow) * (w + 6), dstY: (i ~/ perRow) * (h + 6));
    }
    await t.runAsync(() => File('$dir/menu-frames.png').writeAsBytes(img.encodePng(sheet)));
    debugPrint('PICTURE $dir/menu-frames.png');
  });

  testWidgets('a picture of the grid with its floating toolbars', (t) async {
    t.view.physicalSize = const Size(780, 1000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final library = LibraryModel.forTest('unused');
    await t.runAsync(() async => library.thumbs = await ThumbStore.create());
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
        home: Scaffold(
          extendBody: true,
          body: Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const Scaffold(body: SizedBox()))),
          bottomNavigationBar: FloatingNavBar(places: Place.primary, current: Place.allFolders, onTap: (_) {}),
        ),
      ),
    ));
    await t.pump();
    Navigator.of(t.element(find.byType(SizedBox).first)).push(MaterialPageRoute(builder: (_) => GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 30; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('gridTools')), findsOneWidget);
    expect(find.byKey(const ValueKey('gridTitle')), findsOneWidget);
    await t.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = File('${(await getTemporaryDirectory()).path}/grid-toolbars.png');
      await out.writeAsBytes(png!.buffer.asUint8List());
      debugPrint('PICTURE ${out.path}');
    });
  });
}
