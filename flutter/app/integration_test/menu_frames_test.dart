import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/main.dart' show appTheme;
import 'package:twimshelf/widgets/choice_menu.dart';

/// Frames of the choice menu opening and closing, with the app's theme, close up: a contact sheet
/// to look at (corners, shadow, the pill).
///   flutter test integration_test/menu_frames_test.dart -d DEVICE
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frames', (t) async {
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.load();
    });
    final key = GlobalKey();
    var value = 0;
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: SafeArea(
            child: StatefulBuilder(
              builder: (c, set) => ListTile(
                title: const Text('外观'),
                trailing: ChoiceMenu<int>(
                  key: const ValueKey('menu'),
                  value: value,
                  items: const [(0, '自动'), (1, '浅色'), (2, '深色')],
                  onChanged: (v) => set(() => value = v),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    final frames = <img.Image>[];
    final at = t.getRect(find.byKey(const ValueKey('menu')));
    const scale = 2.0;
    Future<void> shot() async {
      await t.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: scale);
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final whole = img.Image.fromBytes(width: image.width, height: image.height, bytes: raw!.buffer, numChannels: 4);
        final x = ((at.right - 190) * scale).round().clamp(0, image.width - 1);
        final y = ((at.top - 16) * scale).round().clamp(0, image.height - 1);
        final w = (210 * scale).round().clamp(1, image.width - x), h = (210 * scale).round().clamp(1, image.height - y);
        frames.add(img.copyCrop(whole, x: x, y: y, width: w, height: h));
      });
    }

    await shot();
    await t.tap(find.byKey(const ValueKey('menu')));
    for (var i = 0; i < 9; i++) {
      await t.pump(const Duration(milliseconds: 16));
      await shot();
    }
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('深色').last);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 16));
      await shot();
    }
    final w = frames.first.width, h = frames.first.height;
    const perRow = 5;
    final sheet = img.Image(width: (w + 6) * perRow, height: (h + 6) * ((frames.length + perRow - 1) ~/ perRow));
    img.fill(sheet, color: img.ColorRgb8(255, 0, 255));
    for (var i = 0; i < frames.length; i++) {
      img.compositeImage(sheet, frames[i], dstX: (i % perRow) * (w + 6), dstY: (i ~/ perRow) * (h + 6));
    }
    final dir = Directory.systemTemp.path;
    await t.runAsync(() => File('$dir/menu-frames-close.png').writeAsBytes(img.encodePng(sheet)));
    debugPrint('PICTURE $dir/menu-frames-close.png');
  });
}
