import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:math' show sqrt;
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:percevia/models/face_data.dart';
import 'package:percevia/services/face_detection_service.dart';
import 'package:percevia/services/facenet_service.dart';
import 'package:percevia/services/face_storage_service.dart';
import 'package:percevia/services/output_language_service.dart';

enum RegistrationStep {
  idle,
  step1Front,
  step2Left,
  step3Right,
  step4Up,
  step5Down,
  step6Smile,
  processing,
  success,
  error,
}

class RegistrationController {
  final FlutterTts tts;
  final FaceDetectionService faceDetectionService;
  final FaceNetService faceNetService;
  final FaceStorageService storageService;
  String outputLanguage;
  
  /// Callback to notify UI when state changes
  void Function()? onStateChanged;

  RegistrationStep _currentStep = RegistrationStep.idle;
  final List<List<double>> _collectedEmbeddings = [];

  RegistrationController({
    required this.tts,
    required this.faceDetectionService,
    required this.faceNetService,
    required this.storageService,
    this.outputLanguage = OutputLanguageService.defaultLanguage,
    this.onStateChanged,
  });

  RegistrationStep get currentStep => _currentStep;
  List<List<double>> get collectedEmbeddings => _collectedEmbeddings;
  int get embeddingCount => _collectedEmbeddings.length;

  /// Start registration flow
  Future<void> startRegistration() async {
    _currentStep = RegistrationStep.step1Front;
    _collectedEmbeddings.clear();

    await _speakLocalized('Face the camera');
  }

  /// Capture embedding from current frame (manual capture)
  Future<void> captureFrame(CameraImage cameraImage) async {
    if (_currentStep == RegistrationStep.idle ||
        _currentStep == RegistrationStep.processing ||
        _currentStep == RegistrationStep.success ||
        _currentStep == RegistrationStep.error) {
      return;
    }

    try {
      // Crop and align face
      final faceBytes = await faceDetectionService.cropAndAlignFace(
        cameraImage,
      );

      if (faceBytes != null) {
        final embedding = await faceNetService.getEmbedding(faceBytes);
        if (embedding.isNotEmpty) {
          _collectedEmbeddings.add(embedding);
          await _speakLocalized('Captured!');
          moveToNextStep();
        }
      } else {
        await _speakLocalized('No face detected. Try again.');
      }
    } catch (e) {
      debugPrint('Error capturing frame: $e');
      await _speakLocalized('Error capturing frame. Try again.');
    }
  }

  /// Move to next registration step
  void moveToNextStep() {
    switch (_currentStep) {
      case RegistrationStep.step1Front:
        _currentStep = RegistrationStep.step2Left;
        Future.delayed(const Duration(milliseconds: 800), () {
          _speakLocalized('Turn left');
        });
      case RegistrationStep.step2Left:
        _currentStep = RegistrationStep.step3Right;
        Future.delayed(const Duration(milliseconds: 800), () {
          _speakLocalized('Now turn right');
        });
      case RegistrationStep.step3Right:
        _currentStep = RegistrationStep.step4Up;
        Future.delayed(const Duration(milliseconds: 800), () {
          _speakLocalized('Look up');
        });
      case RegistrationStep.step4Up:
        _currentStep = RegistrationStep.step5Down;
        Future.delayed(const Duration(milliseconds: 800), () {
          _speakLocalized('Look down');
        });
      case RegistrationStep.step5Down:
        _currentStep = RegistrationStep.step6Smile;
        Future.delayed(const Duration(milliseconds: 800), () {
          _speakLocalized('Smile');
        });
      case RegistrationStep.step6Smile:
        _finishRegistration();
      default:
        break;
    }
  }

  /// Finish registration
  Future<void> _finishRegistration() async {
    if (_collectedEmbeddings.length < 6) {
      _currentStep = RegistrationStep.error;
      onStateChanged?.call();
      await _speakLocalized('Not enough faces captured. Please try again.');
      return;
    }

    _currentStep = RegistrationStep.processing;
    onStateChanged?.call();
    await _speakLocalized('Processing. Please wait.');

    try {
      // Note: Master embedding is calculated in completeRegistration() when saving with name
      // This just marks the capture phase as complete
      _currentStep = RegistrationStep.success;
      onStateChanged?.call();
      await _speakLocalized(
        'Faces captured successfully! Please enter a name to complete registration.',
      );
    } catch (e) {
      debugPrint('Error finishing registration: $e');
      _currentStep = RegistrationStep.error;
      onStateChanged?.call();
      await _speakLocalized('Error during registration. Please try again.');
    }
  }

  Future<void> speakCue(String englishText) async {
    await _speakLocalized(englishText);
  }

  Future<void> _speakLocalized(String englishText) async {
    final localized = OutputLanguageService.localizeSpeechText(
      outputLanguage,
      englishText,
    );
    await tts.speak(localized);
  }

  /// Calculate average embedding from multiple embeddings, then L2-normalize
  List<double> _calculateAverageEmbedding(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];

    final dimension = embeddings.first.length;
    final average = List<double>.filled(dimension, 0.0);

    for (final embedding in embeddings) {
      for (int i = 0; i < dimension; i++) {
        average[i] += embedding[i];
      }
    }

    for (int i = 0; i < dimension; i++) {
      average[i] /= embeddings.length;
    }

    // L2-normalize the averaged embedding so cosine similarity works correctly.
    // The average of L2-normalized vectors is NOT itself L2-normalized.
    double norm = 0.0;
    for (final v in average) {
      norm += v * v;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < dimension; i++) {
        average[i] /= norm;
      }
    }

    return average;
  }

  /// Cancel registration
  void cancel() {
    _currentStep = RegistrationStep.idle;
    _collectedEmbeddings.clear();
    _storedFaceBytes = null;
  }

  // Store representative face bytes for local Gemma verification
  List<int>? _storedFaceBytes;
  
  /// Set the representative face image for local Gemma verification
  void setStoredFaceBytes(List<int> bytes) {
    _storedFaceBytes = List<int>.from(bytes);
  }

  /// Complete registration by saving to storage
  Future<bool> completeRegistration(String personName, {String? faceDescription}) async {
    debugPrint('[Registration] completeRegistration called for: $personName');
    debugPrint('[Registration] Current step: $_currentStep');
    debugPrint('[Registration] Collected embeddings count: ${_collectedEmbeddings.length}');
    
    if (_currentStep != RegistrationStep.success ||
        _collectedEmbeddings.length < 6) {
      debugPrint('[Registration] Validation failed - returning false');
      return false;
    }

    try {
      // IMPORTANT: Create deep copy of embeddings to prevent reference issues
      // when cancel() clears the list after saving
      final embeddingsCopy = _collectedEmbeddings
          .map((e) => List<double>.from(e))
          .toList();
      
      debugPrint('[Registration] Created embeddings copy with ${embeddingsCopy.length} embeddings');
      
      final masterEmbedding = _calculateAverageEmbedding(embeddingsCopy);
      debugPrint('[Registration] Master embedding length: ${masterEmbedding.length}');
      
      final person = FacePerson(
        name: personName,
        embeddings: embeddingsCopy,
        masterEmbedding: masterEmbedding,
        captureCount: embeddingsCopy.length,
        faceDescription: faceDescription,
        storedFaceBytes: _storedFaceBytes,
      );
      
      debugPrint('[Registration] Created FacePerson: ${person.name} with ${person.embeddings.length} embeddings');
      if (faceDescription != null) {
        debugPrint('[Registration] Face description: ${faceDescription.substring(0, faceDescription.length.clamp(0, 50))}...');
      }
      if (_storedFaceBytes != null) {
        debugPrint('[Registration] Stored face bytes: ${_storedFaceBytes!.length} bytes');
      }

      await storageService.registerPerson(person);
      debugPrint('[Registration] Successfully saved to storage');
      return true;
    } catch (e) {
      debugPrint('[Registration] Error saving registration: $e');
      return false;
    }
  }

  void dispose() {
    // Cleanup if needed
    _storedFaceBytes = null;
  }
}
