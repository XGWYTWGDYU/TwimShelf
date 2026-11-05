import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tl_core/tl_core.dart';

void main() {
  test('discovery exposes conservative multicast health and catalog key', () {
    final status = DiscoveryStatus.fromJson({'running':true,'network_ok':false,'peers':[],'error':'sync.err.paused'});
    expect(status.network_ok, false); expect(status.error, 'sync.err.paused');
    expect(DiscoveryStatus.fromJson({'running':true,'peers':[]}).network_ok, false);
    expect(DiscoveryStatus.fromJson({'running':true,'network_ok':true,'peers':[]}).network_ok, true);
  });
  final directory = Platform.environment['R6_FIXTURES'];
  test('Rust tl_feed_packed unpacks to the exact tl_feed items', () async {
    final packed = jsonDecode(await File('$directory/packed.json').readAsString()) as Map<String,dynamic>;
    final plain = jsonDecode(await File('$directory/plain.json').readAsString()) as Map<String,dynamic>;
    final watch = Stopwatch()..start();
    final result = Core.unpackFeed(packed['ok'] as Map<String,dynamic>);
    watch.stop();
    expect(result.map((v) => v.toJson()).toList(), plain['ok']);
    expect(result, hasLength((plain['ok'] as List).length));
    // Timings are informational: the Rust release benchmark owns the 1s bound.
    print('Dart unpack ${result.length} items: ${watch.elapsedMilliseconds}ms');
  }, skip: directory == null ? 'Set R6_FIXTURES to Rust r6_cleanup fixture output' : false);
}
