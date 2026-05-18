import 'package:flutter/foundation.dart';

import 'gemini_remote_provider.dart';
import 'gemma_local_provider.dart';
import 'gemma_local_service.dart';
import 'llm_provider.dart';

/// Why the on-device Gemma model is being requested by the router.
enum GemmaNeedReason {
  /// A Gemini call produced nothing (no key, no network, server error,
  /// timeout). The UI decides whether this is truly an offline situation.
  geminiUnavailable,

  /// The free Gemini request budget for this session has been spent, so all
  /// further requests must be served on-device.
  geminiQuotaExhausted,
}

/// Routes describe / voice-input requests with a one-way switch to Gemma:
///
/// * **No local model yet** — the first [_maxGeminiRequests] requests go to
///   the Gemini API. When the budget is spent (or a call fails) the router
///   asks the UI, via [onGemmaRequired], to offer the model download.
/// * **Local model present** — every request (this session and all future
///   ones, since the file persists) is served by Gemma and Gemini is never
///   contacted again.
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

  // Latched true the first time the downloaded model is detected. Once set,
  // Gemini is never contacted again for the lifetime of the process.
  bool _gemmaLatched = false;

  /// Invoked when Gemma is needed but not yet on the device. The UI uses this
  /// to surface the one-time model-download prompt.
  void Function(GemmaNeedReason reason)? onGemmaRequired;

  Future<bool> _gemmaAvailable() async {
    if (_gemmaLatched) return true;
    final present = await GemmaLocalService.instance.isModelPresent();
    if (present) _gemmaLatched = true;
    return present;
  }

  @override
  Future<void> initialize() async {
    await _remote.initialize();
    // Only warm the native runtime if the model has actually been
    // downloaded; touching the local service when the file is absent throws.
    if (await _gemmaAvailable()) {
      await _local.initialize();
    }
  }

  @override
  Future<LlmResponse?> generate(LlmRequest request) async {
    if (await _gemmaAvailable()) {
      debugPrint('[GeminiFirstFallback] Gemma present — local only');
      return _local.generate(request);
    }

    if (_requestCount < _maxGeminiRequests) {
      _requestCount++;
      final remote = await _remote.generate(request);
      if (remote != null && remote.text.trim().isNotEmpty) {
        debugPrint('[GeminiFirstFallback] served by Gemini '
            '(request #$_requestCount)');
        if (_requestCount >= _maxGeminiRequests) {
          onGemmaRequired?.call(GemmaNeedReason.geminiQuotaExhausted);
        }
        return remote;
      }
      // Gemini produced nothing and there is no local model to fall back to.
      debugPrint('[GeminiFirstFallback] Gemini unavailable, no local Gemma');
      onGemmaRequired?.call(GemmaNeedReason.geminiUnavailable);
      return null;
    }

    debugPrint('[GeminiFirstFallback] Gemini budget spent, Gemma missing');
    onGemmaRequired?.call(GemmaNeedReason.geminiQuotaExhausted);
    return null;
  }

  @override
  Stream<String> generateStream(LlmRequest request) async* {
    if (await _gemmaAvailable()) {
      debugPrint('[GeminiFirstFallback] Gemma present — local only');
      yield* _local.generateStream(request);
      return;
    }

    if (_requestCount < _maxGeminiRequests) {
      _requestCount++;
      // Gemini has no incremental stream; fetch the full response and decide
      // success/failure before yielding so a failure surfaces cleanly.
      final remote = await _remote.generate(request);
      if (remote != null && remote.text.trim().isNotEmpty) {
        debugPrint('[GeminiFirstFallback] served by Gemini '
            '(request #$_requestCount)');
        yield remote.text;
        if (_requestCount >= _maxGeminiRequests) {
          onGemmaRequired?.call(GemmaNeedReason.geminiQuotaExhausted);
        }
        return;
      }
      debugPrint('[GeminiFirstFallback] Gemini unavailable, no local Gemma');
      onGemmaRequired?.call(GemmaNeedReason.geminiUnavailable);
      return;
    }

    debugPrint('[GeminiFirstFallback] Gemini budget spent, Gemma missing');
    onGemmaRequired?.call(GemmaNeedReason.geminiQuotaExhausted);
  }

  @override
  Future<void> dispose() async {
    await _remote.dispose();
    await _local.dispose();
  }
}
