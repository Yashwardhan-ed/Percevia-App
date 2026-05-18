import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'llm_provider.dart';

class GeminiRemoteProvider implements LlmProvider {
  GeminiRemoteProvider({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  String get providerName => 'gemini-remote';

  Future<bool> isAvailable() async =>
      (dotenv.env['GEMINI_API_KEY'] ?? '').isNotEmpty;

  @override
  Future<void> initialize() async {}

  @override
  Future<LlmResponse?> generate(LlmRequest request) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('[GeminiRemoteProvider] Gemini API key not configured');
      return null;
    }

    final imageBytes = request.imageBytes;
    if (imageBytes == null) {
      debugPrint('[GeminiRemoteProvider] request has no image bytes');
      return null;
    }

    const modelName = 'gemini-2.5-flash-lite';
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': request.prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': request.temperature ?? 0.2,
        'maxOutputTokens': request.maxTokens ?? 300,
        'topK': request.topK ?? 32,
      },
    });

    try {
      final response = await _httpClient
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: requestBody,
          )
          .timeout(request.timeout);

      if (response.statusCode != 200) {
        debugPrint(
          '[GeminiRemoteProvider] request failed (${response.statusCode})',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);
      final text =
          (decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '')
              .toString()
              .trim();
      if (text.isEmpty) {
        debugPrint('[GeminiRemoteProvider] empty response');
        return null;
      }

      return LlmResponse(text: text);
    } on TimeoutException catch (e) {
      debugPrint('[GeminiRemoteProvider] request timed out: $e');
      return null;
    } catch (e) {
      debugPrint('[GeminiRemoteProvider] request error: $e');
      return null;
    }
  }

  @override
  Stream<String> generateStream(LlmRequest request) async* {
    final response = await generate(request);
    if (response != null && response.text.isNotEmpty) {
      yield response.text;
    }
  }

  @override
  Future<void> dispose() async {
    _httpClient.close();
  }
}
