import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:math' as math;
import 'perf_log.dart';

class FaceNetService {
  Interpreter? _interpreter;
  // Runs inference on a background isolate so the ~tens-of-ms native call
  // (plus serialization) doesn't block the UI thread during recognition.
  IsolateInterpreter? _isolateInterpreter;
  bool _isInitialized = false;

  // MobileFaceNet input size
  static const int inputSize = 112;
  
  // Output size (usually 192 for MobileFaceNet, 512 for ArcFace)
  int _outputSize = 192; 

  /// Get the raw cropped face bytes (for local LLM comparison)
  List<int>? lastCroppedFaceBytes;

  Future<List<double>> getEmbedding(List<int> alignedFaceBytes) async {
    if (!_isInitialized) {
      await _initialize();
    }

    if (_interpreter == null || _isolateInterpreter == null) {
      debugPrint('[FaceNet] Interpreter not initialized');
      return [];
    }

    try {
      // Store the cropped face for optional local LLM verification
      lastCroppedFaceBytes = alignedFaceBytes;
      
      // Decode image
      img.Image? image = img.decodeImage(Uint8List.fromList(alignedFaceBytes));
      if (image == null) {
        debugPrint('[FaceNet] Failed to decode image');
        return [];
      }

      // Resize to required input size (112x112)
      image = img.copyResize(image, width: inputSize, height: inputSize);

      // Preprocess image with proper normalization
      final input = _preProcess(image);

      // Output buffer - Shape: [1, outputSize]
      var output = List.generate(1, (i) => List.filled(_outputSize, 0.0));

      // Run inference on the background isolate.
      await _isolateInterpreter!.run(input, output);

      // Flatten output
      final embedding = List<double>.from(output[0]);
      
      // Validate embedding is not all zeros or NaN
      if (embedding.every((e) => e == 0) || embedding.any((e) => e.isNaN)) {
        debugPrint('[FaceNet] Invalid embedding produced (all zeros or NaN)');
        return [];
      }
      
      // Normalize embedding (L2 norm) - essential for cosine similarity
      final normalized = _normalize(embedding);
      
      debugPrint('[FaceNet] Embedding generated: ${normalized.length} dims, norm: ${_calculateNorm(normalized).toStringAsFixed(4)}');
      
      return normalized;
    } catch (e, stackTrace) {
      debugPrint('[FaceNet] Error generating embedding: $e');
      debugPrint('[FaceNet] Stack: $stackTrace');
      return [];
    }
  }

  Future<void> _initialize() async {
    try {
      // Scale threads to the device instead of a fixed 4 — oversubscribing
      // a weak big.LITTLE CPU hurts more than it helps.
      final options = InterpreterOptions()
        ..threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
      
      // Load model
      _interpreter = await Perf.time(
        'FaceNet load',
        () => Interpreter.fromAsset(
          'assets/models/mobile_face_net.tflite',
          options: options,
        ),
      );
      
      // Get input/output details to verify
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);
      
      debugPrint('[FaceNet] Model Loaded Successfully');
      debugPrint('[FaceNet] Input Shape: ${inputTensor.shape}');
      debugPrint('[FaceNet] Output Shape: ${outputTensor.shape}');
      debugPrint('[FaceNet] Input Type: ${inputTensor.type}');
      debugPrint('[FaceNet] Output Type: ${outputTensor.type}');
      
      // Update output size based on model
      _outputSize = outputTensor.shape[1];

      // Wrap the loaded interpreter so .run() executes off the main
      // isolate. _interpreter must stay alive — IsolateInterpreter uses
      // its native address.
      _isolateInterpreter =
          await IsolateInterpreter.create(address: _interpreter!.address);

      _isInitialized = true;
    } catch (e) {
      debugPrint('[FaceNet] Failed to load model: $e');
      _isInitialized = false;
    }
  }

  /// Preprocess image: Normalize pixel values to [-1, 1]
  /// This is the standard preprocessing for MobileFaceNet/ArcFace models
  List _preProcess(img.Image image) {
    // getBytes(rgb) returns a flat inputSize*inputSize*3 buffer in exactly
    // the order the model wants — far cheaper than inputSize*inputSize
    // getPixel() Pixel allocations + a nested List tree (heavy GC on the
    // hot recognition path). Same standard normalization: (v-127.5)/128.
    final input = Float32List(1 * inputSize * inputSize * 3);
    final bytes = image.getBytes(order: img.ChannelOrder.rgb);
    for (int i = 0; i < input.length; i++) {
      input[i] = (bytes[i] - 127.5) / 128.0;
    }
    return input.reshape([1, inputSize, inputSize, 3]);
  }
  
  /// L2 normalize the embedding vector
  List<double> _normalize(List<double> embedding) {
    double norm = _calculateNorm(embedding);
    if (norm == 0 || norm.isNaN) return embedding;
    return embedding.map((e) => e / norm).toList();
  }
  
  double _calculateNorm(List<double> embedding) {
    double sum = 0;
    for (var x in embedding) {
      sum += x * x;
    }
    return math.sqrt(sum);
  }

  /// Calculate cosine similarity between two embeddings
  /// Returns value between -1 and 1 (1 = identical, 0 = orthogonal, -1 = opposite)
  static double cosineSimilarity(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      throw ArgumentError('Embeddings must have same length');
    }
    
    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;
    
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }
    
    norm1 = math.sqrt(norm1);
    norm2 = math.sqrt(norm2);
    
    if (norm1 == 0 || norm2 == 0) return 0.0;
    
    return dotProduct / (norm1 * norm2);
  }
  
  /// Calculate Euclidean distance between two embeddings
  static double euclideanDistance(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      throw ArgumentError('Embeddings must have same length');
    }

    double sum = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      final diff = embedding1[i] - embedding2[i];
      sum += diff * diff;
    }

    return math.sqrt(sum);
  }

  bool get isInitialized => _isInitialized;

  void dispose() {
    // Close the isolate wrapper before the interpreter it points at.
    unawaited(_isolateInterpreter?.close());
    _isolateInterpreter = null;
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
    lastCroppedFaceBytes = null;
  }
}
