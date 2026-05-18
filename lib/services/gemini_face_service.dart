import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Gemini-based face recognition service for soft matching
/// Uses visual reasoning instead of embeddings
class GeminiFaceService {
  final http.Client _httpClient;
  
  GeminiFaceService({http.Client? httpClient}) 
      : _httpClient = httpClient ?? http.Client();

  /// Generate a face description for storage during registration
  /// Returns a textual description of facial features
  Future<String?> generateFaceDescription(List<int> imageBytes) async {
    try {
      final base64Image = base64Encode(imageBytes);
      
      const prompt = '''Describe this person's face for later identification. Focus on:
- Apparent gender and age range
- Face shape (oval, round, square, etc.)
- Hair color, style, and length
- Eye characteristics (shape, color if visible)
- Nose and mouth features
- Any distinctive features (glasses, facial hair, moles, etc.)
- Skin tone

Be specific and concise. Output only the description, no preamble.''';

      final response = await _callGemini(base64Image, prompt);
      return response;
    } catch (e) {
      debugPrint('[GeminiFace] Error generating description: $e');
      return null;
    }
  }

  /// Compare a captured face against a stored description
  /// Returns confidence score 0-100
  Future<int> compareFaceToDescription(
    List<int> capturedImageBytes, 
    String storedDescription,
  ) async {
    try {
      final base64Image = base64Encode(capturedImageBytes);
      
      final prompt = '''You are a face matching assistant.

STORED PERSON DESCRIPTION:
$storedDescription

TASK: Look at this image and determine if it matches the stored description.

Rate the match from 0 to 100:
- 80-100: Very likely the same person
- 60-79: Possibly the same person
- 40-59: Uncertain
- 0-39: Likely different person

Output ONLY a number between 0 and 100, nothing else.''';

      final response = await _callGemini(base64Image, prompt);
      if (response == null) return 0;
      
      // Parse the confidence score
      final score = int.tryParse(response.trim().replaceAll(RegExp(r'[^0-9]'), ''));
      return score?.clamp(0, 100) ?? 0;
    } catch (e) {
      debugPrint('[GeminiFace] Error comparing face: $e');
      return 0;
    }
  }

  /// Direct image-to-image comparison using Gemini
  /// Compares two face images directly
  Future<int> compareTwoFaces(
    List<int> image1Bytes,
    List<int> image2Bytes,
  ) async {
    try {
      final base64Image1 = base64Encode(image1Bytes);
      final base64Image2 = base64Encode(image2Bytes);
      
      const prompt = '''Compare these two face images.
Are they the same person?

Rate the match from 0 to 100:
- 80-100: Very likely the same person
- 60-79: Possibly the same person  
- 40-59: Uncertain
- 0-39: Likely different person

Output ONLY a number between 0 and 100, nothing else.''';

      final response = await _callGeminiWithTwoImages(base64Image1, base64Image2, prompt);
      if (response == null) return 0;
      
      final score = int.tryParse(response.trim().replaceAll(RegExp(r'[^0-9]'), ''));
      return score?.clamp(0, 100) ?? 0;
    } catch (e) {
      debugPrint('[GeminiFace] Error comparing faces: $e');
      return 0;
    }
  }

  /// Check if image contains a valid face for recognition
  Future<bool> validateFaceImage(List<int> imageBytes) async {
    try {
      final base64Image = base64Encode(imageBytes);
      
      const prompt = '''Is there exactly one clear human face in this image suitable for identification?
Requirements:
- Face is visible and not obscured
- Face is reasonably frontal (not extreme profile)
- Image is not too blurry

Answer only YES or NO.''';

      final response = await _callGemini(base64Image, prompt);
      return response?.trim().toUpperCase() == 'YES';
    } catch (e) {
      debugPrint('[GeminiFace] Error validating face: $e');
      return false;
    }
  }

  Future<String?> _callGemini(String base64Image, String prompt) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) {
      debugPrint('[GeminiFace] API key not found');
      return null;
    }

    // const modelName = 'gemini-2.5-flash';
    const modelName = 'gemini-2.5-flash-lite';
    // const modelName = 'gemini-2.0-flash';
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image}
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 500,
      }
    });

    try {
      final response = await _httpClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        return decoded['candidates'][0]['content']['parts'][0]['text'];
      } else {
        debugPrint('[GeminiFace] API error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('[GeminiFace] Request failed: $e');
      return null;
    }
  }

  Future<String?> _callGeminiWithTwoImages(
    String base64Image1, 
    String base64Image2, 
    String prompt,
  ) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) return null;

    const modelName = 'gemini-2.0-flash';
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image1}
            },
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image2}
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 100,
      }
    });

    try {
      final response = await _httpClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        return decoded['candidates'][0]['content']['parts'][0]['text'];
      }
      return null;
    } catch (e) {
      debugPrint('[GeminiFace] Two-image comparison failed: $e');
      return null;
    }
  }

  void dispose() {
    // Don't close if shared client
  }
}
