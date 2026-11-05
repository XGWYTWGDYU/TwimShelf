import 'package:flutter_test/flutter_test.dart';
import 'package:tl_llama/tl_llama.dart';

void main() {
  test('an answer cut off inside a character keeps what is whole', () {
    expect(LlamaEngine.decodeAnswer(const [0x63, 0x61, 0x74, 0x2C, 0xE7, 0x8C, 0xAB, 0xE5, 0x92]), 'cat,猫');
    expect(LlamaEngine.decodeAnswer(const [0x63, 0x61, 0x74]), 'cat');
  });

  // No library here, so the worker isolate fails when it gets to the engine. What must not fail is
  // getting there: what is sent along cannot include the engine, whose timer cannot cross isolates.
  test('a job reaches its worker isolate', () async {
    Object? error;
    try {
      await LlamaEngine.instance.describe(weights: 'w', projector: 'p', image: 'i', system: 's', question: 'q');
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect('$error', isNot(contains('unsendable')));
  });
}
