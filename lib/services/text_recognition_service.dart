import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class TextRecognitionService {
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String?> recognizeText(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
      
      String text = recognizedText.text;
      if (text.trim().isEmpty) {
        return null;
      }
      return text;
    } catch (e) {
      debugPrint("Error during text recognition: $e");
      return null;
    }
  }

  void dispose() {
    _textRecognizer.close();
  }
}
