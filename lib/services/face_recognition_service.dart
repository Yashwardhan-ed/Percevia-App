import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'face_storage_service.dart';
import 'face_detection_service.dart';
import 'facenet_service.dart';

/// Recognition result with confidence information
class RecognitionResult {
  final String? name;
  final double confidence; // 0.0 to 1.0
  final String method; // 'embedding' or 'none'
  final double? embeddingSimilarity;

  RecognitionResult({
    this.name,
    required this.confidence,
    required this.method,
    this.embeddingSimilarity,
  });

  bool get isMatch => name != null && name != 'unknown' && confidence >= 0.5;

  @override
  String toString() =>
      'RecognitionResult(name: $name, confidence: ${(confidence * 100).toStringAsFixed(1)}%, method: $method)';
}

class FaceRecognitionService {
  final FaceStorageService _storageService;
  final FaceDetectionService _detectionService;
  final FaceNetService _faceNetService;

  // Bumped when the embedding model or normalization changes so we can warn
  // about embeddings that may have been generated with a different version.
  static const String currentModelVersion = "1.0";

  // Cosine similarity threshold for accepting a match. With L2-normalized
  // MobileFaceNet embeddings, same-person scores typically land in 0.5-0.9
  // and different-person scores in 0.1-0.4. 0.45 sits at a reasonable
  // operating point; raise it (e.g. to 0.55) for stricter matching, lower
  // it (to ~0.4) if too many faces come back as "unknown".
  static const double _matchThreshold = 0.45;

  // Required gap between best and second-best similarity before we trust
  // the best match. Avoids confusing two people who score similarly.
  static const double _marginRequired = 0.05;

  FaceRecognitionService({
    required FaceStorageService storageService,
    required FaceDetectionService detectionService,
    required FaceNetService faceNetService,
  })  : _storageService = storageService,
        _detectionService = detectionService,
        _faceNetService = faceNetService;

  /// Recognize a person from raw image bytes (e.g. a captured still).
  /// Returns the person's name if recognized, 'unknown' if a face is detected
  /// but doesn't match anyone, or null if no face is detected / on error.
  Future<String?> recognizePerson(List<int> imageBytes) async {
    try {
      debugPrint('[Recognition] === Image bytes recognition ===');
      final faceImage = await _detectionService.detectSingleFace(imageBytes);
      if (faceImage == null) {
        debugPrint('[Recognition] No face detected in image');
        return null;
      }
      return _matchEmbedding(await _faceNetService.getEmbedding(faceImage));
    } catch (e, stackTrace) {
      debugPrint('[Recognition] Error: $e');
      debugPrint('[Recognition] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Recognize a person directly from a CameraImage (image stream path).
  /// Avoids disk I/O by feeding camera frames straight into detection.
  Future<String?> recognizePersonFromCamera(CameraImage cameraImage) async {
    try {
      debugPrint('[Recognition] === Camera stream recognition ===');
      final faceImage = await _detectionService.cropAndAlignFace(cameraImage);
      if (faceImage == null) {
        debugPrint('[Recognition] No face detected in camera frame');
        return null;
      }
      return _matchEmbedding(await _faceNetService.getEmbedding(faceImage));
    } catch (e, stackTrace) {
      debugPrint('[Recognition] Error in camera recognition: $e');
      debugPrint('[Recognition] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Shared decision logic: takes a fresh embedding, finds the best match
  /// against stored persons, and returns name / 'unknown' / null.
  Future<String?> _matchEmbedding(List<double> embedding) async {
    if (embedding.isEmpty) {
      debugPrint('[Recognition] Failed to generate embedding');
      return null;
    }

    final persons = await _storageService.getAllPersons();
    if (persons.isEmpty) {
      debugPrint('[Recognition] No registered persons');
      return null;
    }

    final similarities = <_PersonSimilarity>[];
    for (final person in persons) {
      if (person.modelVersion != currentModelVersion) {
        debugPrint(
            '[Recognition] ⚠️  ${person.name} stored with model version ${person.modelVersion}, current $currentModelVersion');
      }

      double maxSim = -1.0;
      for (final stored in person.embeddings) {
        if (stored.length != embedding.length) continue;
        final sim = FaceNetService.cosineSimilarity(embedding, stored);
        if (sim > maxSim) maxSim = sim;
      }
      if (person.masterEmbedding != null &&
          person.masterEmbedding!.length == embedding.length) {
        final sim =
            FaceNetService.cosineSimilarity(embedding, person.masterEmbedding!);
        if (sim > maxSim) maxSim = sim;
      }

      if (maxSim > -1.0) {
        similarities.add(_PersonSimilarity(person.name, maxSim, person.id));
        debugPrint(
            '[Recognition]   ${person.name}: ${(maxSim * 100).toStringAsFixed(1)}%');
      }
    }

    if (similarities.isEmpty) {
      debugPrint('[Recognition] No comparable embeddings');
      return 'unknown';
    }

    similarities.sort((a, b) => b.similarity.compareTo(a.similarity));
    final best = similarities.first;
    final second = similarities.length > 1 ? similarities[1] : null;
    final margin = second != null ? best.similarity - second.similarity : 1.0;

    debugPrint(
        '[Recognition] Best: ${best.name} ${(best.similarity * 100).toStringAsFixed(1)}%, '
        'margin ${(margin * 100).toStringAsFixed(1)}%');

    if (best.similarity >= _matchThreshold && margin >= _marginRequired) {
      debugPrint('[Recognition] ✓ Match: ${best.name}');
      return best.name;
    }
    debugPrint('[Recognition] ✗ Below threshold or insufficient margin');
    return 'unknown';
  }

  /// Detailed recognition result with confidence info, for diagnostic UI.
  Future<RecognitionResult> recognizePersonDetailed(List<int> imageBytes) async {
    try {
      final faceImage = await _detectionService.detectSingleFace(imageBytes);
      if (faceImage == null) {
        return RecognitionResult(name: null, confidence: 0.0, method: 'none');
      }

      final embedding = await _faceNetService.getEmbedding(faceImage);
      if (embedding.isEmpty) {
        return RecognitionResult(name: null, confidence: 0.0, method: 'none');
      }

      final persons = await _storageService.getAllPersons();
      if (persons.isEmpty) {
        return RecognitionResult(
            name: 'unknown', confidence: 0.0, method: 'embedding');
      }

      double maxSim = -1.0;
      String? bestName;
      for (final person in persons) {
        for (final stored in person.embeddings) {
          if (stored.length != embedding.length) continue;
          final sim = FaceNetService.cosineSimilarity(embedding, stored);
          if (sim > maxSim) {
            maxSim = sim;
            bestName = person.name;
          }
        }
      }

      // Map cosine similarity (-1..1) into a 0..1 confidence value for UI.
      final confidence = ((maxSim + 1) / 2).clamp(0.0, 1.0);

      if (maxSim >= _matchThreshold) {
        return RecognitionResult(
          name: bestName,
          confidence: confidence,
          method: 'embedding',
          embeddingSimilarity: maxSim,
        );
      }
      return RecognitionResult(
        name: 'unknown',
        confidence: confidence,
        method: 'embedding',
        embeddingSimilarity: maxSim,
      );
    } catch (e) {
      debugPrint('[Recognition] Error in detailed recognition: $e');
      return RecognitionResult(name: null, confidence: 0.0, method: 'error');
    }
  }

  void dispose() {}
}

class _PersonSimilarity {
  final String name;
  final double similarity;
  final String personId;

  _PersonSimilarity(this.name, this.similarity, this.personId);
}
