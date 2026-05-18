import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'gemma_local_service.dart';
import 'llm_provider.dart';

class GemmaLocalProvider implements LlmProvider {
  GemmaLocalProvider({GemmaLocalService? localService})
      : _localService = localService ?? GemmaLocalService.instance;

  final GemmaLocalService _localService;
  final LinkedHashMap<String, String> _responseCache = LinkedHashMap<String, String>();
  static const int _maxCacheEntries = 20;

  @override
  Future<void> initialize() => _localService.initialize();

  @override
  Future<LlmResponse?> generate(LlmRequest request) async {
    final cacheKey = request.cacheKey;
    if (cacheKey != null && _responseCache.containsKey(cacheKey)) {
      final cached = _responseCache.remove(cacheKey)!;
      _responseCache[cacheKey] = cached;
      return LlmResponse(text: cached, fromCache: true);
    }

    final cfg = _resolveConfig(request);
    try {
      final future = request.imageBytes == null
          ? _localService.generateTextResponse(
              prompt: request.prompt,
              temperature: cfg.temperature,
              topK: cfg.topK,
              topP: cfg.topP,
              maxTokens: cfg.maxTokens,
            )
          : _localService.generateImageResponse(
              imageBytes: request.imageBytes!,
              prompt: request.prompt,
              temperature: cfg.temperature,
              topK: cfg.topK,
              topP: cfg.topP,
              maxTokens: cfg.maxTokens,
            );

      final text = await future.timeout(request.timeout);
      if (text == null || text.trim().isEmpty) return null;

      final cleaned = text.trim();
      if (cacheKey != null) {
        _responseCache[cacheKey] = cleaned;
        if (_responseCache.length > _maxCacheEntries) {
          _responseCache.remove(_responseCache.keys.first);
        }
      }
      return LlmResponse(text: cleaned);
    } on TimeoutException catch (e) {
      debugPrint(
        '[GemmaLocalProvider] generation timed out after ${request.timeout.inSeconds}s '
        '(maxTokens=${cfg.maxTokens}, hasImage=${request.imageBytes != null}): $e',
      );
      return null;
    } catch (e) {
      debugPrint('[GemmaLocalProvider] generation failed: $e');
      return null;
    }
  }

  @override
  Stream<String> generateStream(LlmRequest request) async* {
    final cfg = _resolveConfig(request);
    final stream = request.imageBytes == null
        ? _localService.generateTextResponseStream(
            prompt: request.prompt,
            temperature: cfg.temperature,
            topK: cfg.topK,
            topP: cfg.topP,
            maxTokens: cfg.maxTokens,
          )
        : _localService.generateImageResponseStream(
            imageBytes: request.imageBytes!,
            prompt: request.prompt,
            temperature: cfg.temperature,
            topK: cfg.topK,
            topP: cfg.topP,
            maxTokens: cfg.maxTokens,
          );

    try {
      yield* stream;
    } on TimeoutException catch (e) {
      debugPrint(
        '[GemmaLocalProvider] stream timed out after ${request.timeout.inSeconds}s '
        '(maxTokens=${cfg.maxTokens}, hasImage=${request.imageBytes != null}): $e',
      );
    } catch (e) {
      debugPrint('[GemmaLocalProvider] stream failed: $e');
    }
  }

  _GenerationConfig _resolveConfig(LlmRequest request) {
    final defaults = switch (request.mode) {
      LlmFeatureMode.describe => const _GenerationConfig(
          temperature: 0.2,
          topK: 40,
          topP: 0.9,
          maxTokens: 360,
        ),
      LlmFeatureMode.briefDescribe => const _GenerationConfig(
          temperature: 0.1,
          topK: 24,
          topP: 0.85,
          maxTokens: 140,
        ),
      LlmFeatureMode.voiceAssistant => const _GenerationConfig(
          temperature: 0.05,
          topK: 20,
          topP: 0.8,
          maxTokens: 180,
        ),
    };

    return _GenerationConfig(
      temperature: request.temperature ?? defaults.temperature,
      topK: request.topK ?? defaults.topK,
      topP: request.topP ?? defaults.topP,
      maxTokens: request.maxTokens ?? defaults.maxTokens,
    );
  }

  @override
  Future<void> dispose() async {
    _responseCache.clear();
  }
}

class _GenerationConfig {
  const _GenerationConfig({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.maxTokens,
  });

  final double temperature;
  final int topK;
  final double topP;
  final int maxTokens;
}
