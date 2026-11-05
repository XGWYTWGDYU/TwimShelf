// Flutter's decoders do not read these on every platform: the core's must, on every one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/widgets/media_image.dart';

// core/tests/data: 64x48 red, synthetic
const heic = 'AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABhm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAOZpcHJwAAAAxWlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAQAAAADAAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcWh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAI0IBAQNwAAADALAAAAMAAAMAHqAUIEHBjE4h7kWVTcCAgYAgogABAAlEAcBjyyEBTJAAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAboAAAAuAAAAAW1kYXQAAAAAAAAAPgAAACooAa+i8veF9P/0nX/+cc7/2SSI1bSL7G9I847X/UR+w2/QLj6ts+ZXduA=';
const avif = 'AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAAD5bWV0YQAAAAAAAAAvaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAFBpY3R1cmVIYW5kbGVyAAAAAA5waXRtAAAAAAABAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAASEAAAAjAAAAKGlpbmYAAAAAAAEAAAAaaW5mZQIAAAAAAQAAYXYwMUNvbG9yAAAAAGppcHJwAAAAS2lwY28AAAAUaXNwZQAAAAAAAABAAAAAMAAAABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAAAAATY29scm5jbHgAAgACAAIAAAAAF2lwbWEAAAAAAAAAAQABBAECgwQAAAArbWRhdAoKAAAAAq/3jV8gCDIVEACjACCBBAgAEACtOfp0HulwCTvU';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, data) in [('sample.heic', heic), ('sample.avif', avif), ('SAMPLE.HEIF', heic)]) {
    testWidgets('$name reaches the screen', (tester) async {
      final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tl-heif-'));
      final file = File('${dir!.path}/$name');
      await tester.runAsync(() => file.writeAsBytes(base64Decode(data)));
      HeifFileImage.cacheDir = dir.path;
      final provider = mediaImage(file.path, cacheWidth: 32, maxSide: 1024);
      ui.Image? shown;
      Object? failed;
      await tester.runAsync(() async {
        final done = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        stream.addListener(ImageStreamListener((info, _) {
          shown = info.image;
          done.complete();
        }, onError: (e, _) {
          failed = e;
          done.complete();
        }));
        await done.future.timeout(const Duration(seconds: 60));
      });
      expect(failed, isNull);
      expect(shown!.width, 32);
      expect(shown!.height, 24);
      final jpeg = await tester.runAsync(() async => Core.displayImage(file.path, 1024, dir.path));
      expect(jpeg, endsWith('.jpg'));
      await tester.runAsync(() => dir.delete(recursive: true));
    });
  }

  testWidgets('a damaged file is an error, not a crash', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tl-heif-'));
    final file = File('${dir!.path}/bad.heic');
    await tester.runAsync(() => file.writeAsString('not a picture'));
    expect(() => Core.displayImage(file.path, 64, dir.path), throwsA(isA<CoreError>()));
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
