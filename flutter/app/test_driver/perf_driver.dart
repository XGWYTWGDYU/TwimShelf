import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

/// Writes what a performance test reports (frames, timeline) under build/perf/.
///   flutter drive --profile -d DEVICE --driver test_driver/perf_driver.dart --target integration_test/browse_scroll_perf_test.dart
Future<void> main() => integrationDriver(responseDataCallback: (data) async {
      if (data == null) return;
      final out = Directory('build/perf')..createSync(recursive: true);
      final timeline = data.remove('timeline');
      if (timeline is Map<String, dynamic>) {
        final t = Timeline.fromJson(timeline);
        await TimelineSummary.summarize(t).writeTimelineToFile('browse_scroll', destinationDirectory: out.path, pretty: false);
      }
      File('${out.path}/browse_scroll_frames.json').writeAsStringSync(jsonEncode(data));
    });
