/// A browser cannot load llama.cpp: the web build has no local model of its own (external AI
/// services work through the server).
class LlamaEngine {
  LlamaEngine._();
  static final instance = LlamaEngine._();
  static bool get isSupported => false;
  Future<String> init(String? backendsDir) => throw const LlamaException('unsupported');
  Future<String> describe({required String weights, required String projector, required String image, required String system, required String question, int maxTokens = 160, int gpuLayers = 999}) =>
      throw const LlamaException('unsupported');
  static String decodeAnswer(List<int> bytes) => String.fromCharCodes(bytes);
  Future<void> unloadAll() async {}
}

class LlamaException implements Exception {
  const LlamaException(this.message);
  final String message;
  @override
  String toString() => message;
}
