import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/platform/video.dart';
import 'package:twimshelf/platform/audio_routes.dart';

class FakeRoutes implements HeadphoneRoutes {
  bool connected = false;
  final events = StreamController<bool>.broadcast();
  @override
  Stream<bool> get changes => events.stream;
  @override
  Future<bool> current() async => connected;
  void update(bool value) {
    connected = value;
    events.add(value);
  }

  @override
  Future<void> dispose() => events.close();
}

class FakeVideo implements VideoEngine {
  final positions = StreamController<Duration>.broadcast(),
      durations = StreamController<Duration>.broadcast();
  final calls = <String>[];
  bool audio = true, looping = false;
  double volumeNow = 0;
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => durations.stream;
  @override
  Duration currentPosition = Duration.zero;
  @override
  Duration currentDuration = const Duration(seconds: 2);
  @override
  Future<void> open(String path) async {
    calls.add('open');
  }

  @override
  Future<void> play() async {
    calls.add('play');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> seek(Duration value) async {
    currentPosition = value;
  }

  @override
  Future<void> rate(double value) async => calls.add('rate:$value');

  @override
  Future<void> volume(double value) async {
    volumeNow = value;
    calls.add('volume:$value');
  }

  @override
  Future<void> loop(bool value) async {
    looping = value;
  }

  @override
  Future<bool> hasAudio() async => audio;
  @override
  Future<Uint8List?> screenshot() async => null;
  @override
  Future<void> dispose() async {
    await positions.close();
    await durations.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('f7a-test-');
    source = File('${root.path}/video.mp4');
    await source.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'headphones policy reads core key, starts muted, and consent is per-video',
    () async {
      // the Mac, phones and tablets only: Windows and Linux have no such setting
      if (Platform.isWindows || Platform.isLinux) return;
      final engine = FakeVideo(), routes = FakeRoutes();
      final player = VideoPlayback(
        engine: engine,
        routes: routes,
        readSetting: (key) {
          expect(key, 'audio.headphonesOnly');
          return 'true';
        },
      );
      await player.open(source.path);
      expect(engine.calls.first, startsWith('volume:0'));
      expect(player.muted.value, isTrue);
      expect(player.needsSpeakerConsent.value, isTrue);
      await player.allowSpeakerForCurrentVideo();
      expect(engine.volumeNow, 100);
      expect(player.needsSpeakerConsent.value, isFalse);
      routes.update(true);
      await Future<void>.delayed(Duration.zero);
      routes.update(false);
      await Future<void>.delayed(Duration.zero);
      expect(engine.volumeNow, 0);
      expect(player.needsSpeakerConsent.value, isTrue);
      await player.allowSpeakerForCurrentVideo();
      await player.open(source.path);
      expect(player.muted.value, isTrue);
      await player.dispose();
    },
  );
  test(
    'manual mute, silent files, settings refresh and playback controls',
    () async {
      final engine = FakeVideo()..audio = false;
      final routes = FakeRoutes();
      var setting = 'true';
      final player = VideoPlayback(
        engine: engine,
        routes: routes,
        readSetting: (_) => setting,
      );
      await player.open(source.path, autoplay: false);
      expect(player.needsSpeakerConsent.value, isFalse);
      setting = 'false';
      await player.refreshAudioPolicy();
      expect(player.muted.value, isFalse);
      await player.setMuted(true);
      await player.play();
      expect(engine.volumeNow, 0);
      await player.pause();
      await player.seek(const Duration(seconds: 10));
      expect(engine.currentPosition, const Duration(seconds: 2));
      await player.seek(const Duration(seconds: -1));
      expect(engine.currentPosition, Duration.zero);
      await player.setLoop(true);
      expect(engine.looping, isTrue);
      expect(engine.calls, containsAll(['open', 'play', 'pause']));
      await player.dispose();
      await expectLater(player.play(), throwsStateError);
    },
  );
  test('unknown settings/routes fail closed; OS route classification is conservative', () {
    expect(headphonesOnlySetting(null), isFalse);
    expect(headphonesOnlySetting('0'), isFalse);
    expect(headphonesOnlySetting('true'), isTrue);
    expect(headphonesOnlySetting('unexpected'), isTrue);
    expect(
      isPrivateLinuxOutput({'active_port': 'analog-output-headphones'}),
      isTrue,
    );
    expect(
      isPrivateLinuxOutput({'active_port': 'analog-output-speaker'}),
      isFalse,
    );
    expect(
      isPrivateLinuxOutput({
        'properties': {'device.bus': 'usb'},
      }),
      isTrue,
    );
    expect(isPrivateLinuxOutput({}), isFalse);
  });
  FeedItem item({String id = 'video-1', MediaKind kind = MediaKind.video}) =>
      FeedItem(
        media_id: id,
        post_id: 'p',
        ordinal: 0,
        kind: kind,
        path: source.path,
      );
  Uint8List frame() {
    final picture = image.Image(width: 160, height: 80, numChannels: 3);
    image.fill(picture, color: image.ColorRgb8(255, 0, 0));
    image.fillRect(
      picture,
      x1: 40,
      y1: 0,
      x2: 119,
      y2: 79,
      color: image.ColorRgb8(0, 255, 0),
    );
    return image.encodePng(picture);
  }

  test('a card\'s poster keeps the video\'s shape', () async {
    final tall = Uint8List.fromList(image.encodeJpg(image.Image(width: 300, height: 600)));
    final posters = VideoPosters(grabFrame: (_, _) async => tall);
    final p = await posters.whole(item(), 200, '${root.path}/cache');
    expect(p, isNotNull);
    final out = image.decodeJpg(await File(p!).readAsBytes())!;
    expect((out.width, out.height), (100, 200));
    expect(await posters.whole(item(), 200, '${root.path}/cache'), p, reason: 'cached');
  });

  test(
    'posters crop centre to square JPEG, cache and coalesce concurrent grabs',
    () async {
      var grabs = 0;
      final posters = VideoPosters(
        grabFrame: (path, at) async {
          grabs++;
          expect(at, const Duration(milliseconds: 500));
          return frame();
        },
      );
      final results = await Future.wait(
        List.generate(
          8,
          (_) => posters.poster(item(), 64, '${root.path}/cache'),
        ),
      );
      expect(grabs, 1);
      expect(results.toSet().length, 1);
      final file = File(results.first!);
      expect(file.path, endsWith('/64/video-1.jpg'));
      final bytes = await file.readAsBytes();
      expect(bytes.take(2), [255, 216]);
      final decoded = image.decodeJpg(bytes)!;
      expect(decoded.width, 64);
      expect(decoded.height, 64);
      expect(decoded.getPixel(32, 32).g, greaterThan(240));
      expect(jpegSide(file), 64);
      final modified = await file.lastModified();
      await posters.poster(item(), 64, '${root.path}/cache');
      expect(grabs, 1);
      expect(await file.lastModified(), modified);
      await file.writeAsString('broken JPEG');
      expect(await posters.poster(item(), 64, '${root.path}/cache'), isNotNull);
      expect(grabs, 2);
    },
  );
  test(
    'poster failures/invalid inputs return null and publish no partial output',
    () async {
      final posters = VideoPosters(
        grabFrame: (_, _) async => Uint8List.fromList([1, 2, 3]),
      );
      expect(await posters.poster(item(), 64, '${root.path}/cache'), isNull);
      expect(
        await posters.poster(item(kind: MediaKind.photo), 64, root.path),
        isNull,
      );
      expect(
        await posters.poster(item(id: '../outside'), 64, root.path),
        isNull,
      );
      expect(await posters.poster(item(), 0, root.path), isNull);
      expect(await Directory('${root.path}/cache').exists(), isFalse);
    },
  );
  test(
    'source changes during frame acquisition never publish a stale poster',
    () async {
      final posters = VideoPosters(
        grabFrame: (_, _) async {
          await source.writeAsBytes([4, 5, 6, 7]);
          return frame();
        },
      );
      expect(await posters.poster(item(), 64, '${root.path}/cache'), isNull);
      expect(await File('${root.path}/cache/64/video-1.jpg').exists(), isFalse);
    },
  );
}
