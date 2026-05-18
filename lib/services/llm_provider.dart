enum LlmFeatureMode {
  describe,
  briefDescribe,
  voiceAssistant,
}

enum LlmRoutingMode {
  localOnly,
  localPreferredRemoteFallback,
}

class LlmRequest {
  const LlmRequest({
    required this.mode,
    required this.prompt,
    this.imageBytes,
    this.temperature,
    this.topK,
    this.topP,
    this.maxTokens,
    this.timeout = const Duration(seconds: 120),
    this.cacheKey,
  });

  final LlmFeatureMode mode;
  final String prompt;
  final List<int>? imageBytes;
  final double? temperature;
  final int? topK;
  final double? topP;
  final int? maxTokens;
  final Duration timeout;
  final String? cacheKey;
}

class LlmResponse {
  const LlmResponse({
    required this.text,
    this.fromCache = false,
  });

  final String text;
  final bool fromCache;
}

abstract class LlmProvider {
  Future<void> initialize();

  Future<LlmResponse?> generate(LlmRequest request);

  /// Streams response token deltas. Concatenating all yielded strings produces
  /// the full response. Implementations are expected to emit nothing and close
  /// the stream on failure (errors are logged, not rethrown).
  Stream<String> generateStream(LlmRequest request);

  Future<void> dispose();
}
