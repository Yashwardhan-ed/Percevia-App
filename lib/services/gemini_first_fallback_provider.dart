import 'package:flutter/foundation.dart';

import 'gemini_remote_provider.dart';
import 'gemma_local_provider.dart';
import 'llm_provider.dart';

/// Routes describe / voice-input requests to the Gemini API first and falls
/// back to on-device Gemma when Gemini is unavailable (no API key, no
/// internet, rate limit / free-tier exhausted, server error, timeout — all
/// of which surface as a null/empty result from [GeminiRemoteProvider]).
///
/// Only the first [_maxGeminiRequests] requests of the session attempt
/// Gemini; every request after that goes straight to Gemma.
class GeminiFirstFallbackProvider implements LlmProvider {
  GeminiFirstFallbackProvider({
    GeminiRemoteProvider? remote,
    GemmaLocalProvider? local,
  })  : _remote = remote ?? GeminiRemoteProvider(),
        _local = local ?? GemmaLocalProvider();

  final GeminiRemoteProvider _remote;
  final GemmaLocalProvider _local;

  static const int _maxGeminiRequests = 2;
  int _requestCount = 0;

  /// Whether this request should try Gemini. Counts every request so the
  /// switch to Gemma is permanent after the first [_maxGeminiRequests],
  /// regardless of whether those attempts succeeded.
  bool _consumeGeminiSlot() {
    final useGemini = _requestCount < _maxGeminiRequests;
    _requestCount++;
    return useGemini;
  }

  @override
  Future<void> initialize() async {
    // Gemma must be warm so the fallback (and post-switch path) is instant.
    await _local.initialize();
    await _remote.initialize();
  }

  @override
  Future<LlmResponse?> generate(LlmRequest request) async {
    if (_consumeGeminiSlot()) {
      final remote = await _remote.generate(request);
      if (remote != null && remote.text.trim().isNotEmpty) {
        debugPrint('[GeminiFirstFallback] served by Gemini '
            '(request #$_requestCount)');
        return remote;
      }
      debugPrint('[GeminiFirstFallback] Gemini unavailable, '
          'falling back to Gemma (request #$_requestCount)');
      return _local.generate(request);
    }
    debugPrint('[GeminiFirstFallback] Gemini quota spent, using Gemma '
        '(request #$_requestCount)');
    return _local.generate(request);
  }

  @override
  Stream<String> generateStream(LlmRequest request) async* {
    if (_consumeGeminiSlot()) {
      // Gemini has no incremental stream; fetch the full response and decide
      // success/failure before yielding so a failure can cleanly fall back
      // to Gemma's real token stream.
      final remote = await _remote.generate(request);
      if (remote != null && remote.text.trim().isNotEmpty) {
        debugPrint('[GeminiFirstFallback] served by Gemini '
            '(request #$_requestCount)');
        yield remote.text;
        return;
      }
      debugPrint('[GeminiFirstFallback] Gemini unavailable, '
          'falling back to Gemma (request #$_requestCount)');
      yield* _local.generateStream(request);
      return;
    }
    debugPrint('[GeminiFirstFallback] Gemini quota spent, using Gemma '
        '(request #$_requestCount)');
    yield* _local.generateStream(request);
  }

  @override
  Future<void> dispose() async {
    await _remote.dispose();
    await _local.dispose();
  }
}
