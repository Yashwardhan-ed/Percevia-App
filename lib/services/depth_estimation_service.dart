import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'perf_log.dart';

/// Monocular depth estimation service using MiDaS v2.1 Small (TFLite).
///
/// Produces an approximate depth map from a single camera image. The model
/// outputs *relative inverse depth*; we convert to approximate meters using
/// a range-based formula calibrated for outdoor pedestrian scenarios.
class DepthEstimationService {
  Interpreter? _interpreter;
  // Runs MiDaS inference off the main isolate so the ~400-650 ms native
  // call doesn't freeze the UI / camera preview during a navigation scan.
  IsolateInterpreter? _isolateInterpreter;
  bool _isInitialized = false;
  bool _isRunning = false;

  /// MiDaS v2.1 Small input size
  static const int inputSize = 256;

  /// Assumed scene depth range for relative → metric conversion.
  /// These values are tuned for a blind user walking outdoors.
  static const double minDepthMeters = 0.5;
  static const double maxDepthMeters = 15.0;

  /// Cached depth map from the last inference run.
  /// Values are approximate distance in meters, sized [inputSize × inputSize].
  Float32List? _cachedDepthMap;

  /// Wall-clock of the last MiDaS inference. The caller uses this to set an
  /// adaptive refresh cadence — fast devices refresh depth more often,
  /// slow/throttling ones back off — without any hardware fingerprinting.
  int? _lastInferenceMs;
  int? get lastInferenceMs => _lastInferenceMs;

  bool get isInitialized => _isInitialized;
  bool get isRunning => _isRunning;
  bool get hasDepthMap => _cachedDepthMap != null;

  /// Initialize the MiDaS interpreter.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final options = InterpreterOptions()
        ..threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);

      _interpreter = await Perf.time(
        'MiDaS load',
        () => Interpreter.fromAsset(
          'assets/models/midas_v2_1_small.tflite',
          options: options,
        ),
      );

      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);

      debugPrint('[DepthEstimation] Model loaded successfully');
      debugPrint('[DepthEstimation] Input shape: ${inputTensor.shape}');
      debugPrint('[DepthEstimation] Output shape: ${outputTensor.shape}');
      debugPrint('[DepthEstimation] Input type: ${inputTensor.type}');
      debugPrint('[DepthEstimation] Output type: ${outputTensor.type}');

      _isolateInterpreter =
          await IsolateInterpreter.create(address: _interpreter!.address);

      _isInitialized = true;
    } catch (e) {
      debugPrint('[DepthEstimation] Failed to load model: $e');
      _isInitialized = false;
    }
  }

  /// Run depth estimation on a camera image (JPEG/PNG bytes).
  ///
  /// This decodes the image, preprocesses it, runs MiDaS inference, and
  /// caches the resulting depth map. The depth map can then be sampled by
  /// [getDistanceAtPoint] for individual YOLO detections.
  ///
  /// Returns `true` if a new depth map was produced.
  Future<bool> estimateDepthFromImageBytes(
    Uint8List imageBytes, {
    required double frameWidth,
    required double frameHeight,
  }) async {
    if (!_isInitialized ||
        _interpreter == null ||
        _isolateInterpreter == null ||
        _isRunning) {
      return false;
    }

    _isRunning = true;
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return false;

      final resized = img.copyResize(
        decoded,
        width: DepthEstimationService.inputSize,
        height: DepthEstimationService.inputSize,
      );

      final sw = Stopwatch()..start();
      _cachedDepthMap = await _runInference(_isolateInterpreter!, resized);
      _lastInferenceMs = sw.elapsedMilliseconds;
      Perf.mark('MiDaS inference', sw.elapsedMilliseconds);
      return true;
    } catch (e) {
      debugPrint('[DepthEstimation] Error during inference: $e');
      return false;
    } finally {
      _isRunning = false;
    }
  }

  /// Run depth estimation directly from a camera frame (YUV planes).
  ///
  /// Converts the first plane to grayscale, then to an RGB image for MiDaS.
  Future<bool> estimateDepthFromCameraImage(
    List<Uint8List> planes,
    int imageWidth,
    int imageHeight,
  ) async {
    if (!_isInitialized ||
        _interpreter == null ||
        _isolateInterpreter == null ||
        _isRunning) {
      return false;
    }

    _isRunning = true;
    try {
      // The YUV Y-plane IS already an 8-bit grayscale image. Instead of
      // materialising a full-resolution img.Image (≈900k setPixelRgb
      // calls at 720p) and then copyResize-ing it — both on the main
      // isolate, which janks the UI — nearest-neighbour downsample the
      // Y-plane directly into the model's input size. ~14× fewer ops and
      // no separate resize pass.
      const target = DepthEstimationService.inputSize;
      final yPlane = planes.first;
      final resized = img.Image(width: target, height: target);
      for (int ty = 0; ty < target; ty++) {
        final sy = (ty * imageHeight) ~/ target;
        final rowBase = sy * imageWidth;
        for (int tx = 0; tx < target; tx++) {
          final sx = (tx * imageWidth) ~/ target;
          final luma = yPlane[rowBase + sx];
          resized.setPixelRgb(tx, ty, luma, luma, luma);
        }
      }

      final sw = Stopwatch()..start();
      _cachedDepthMap = await _runInference(_isolateInterpreter!, resized);
      _lastInferenceMs = sw.elapsedMilliseconds;
      Perf.mark('MiDaS inference', sw.elapsedMilliseconds);
      return true;
    } catch (e) {
      debugPrint('[DepthEstimation] Error during YUV inference: $e');
      return false;
    } finally {
      _isRunning = false;
    }
  }

  /// Sample the cached depth map at a point in the original frame coordinate
  /// space to get approximate distance in meters.
  ///
  /// [x], [y] are in the original frame coordinate system (e.g. YOLO bbox
  /// center coordinates). Returns null if no depth map is cached.
  double? getDistanceAtPoint(double x, double y, double frameWidth, double frameHeight) {
    if (_cachedDepthMap == null) return null;

    // Map frame coordinates to the 256×256 depth map
    final mapX = ((x / frameWidth) * inputSize).round().clamp(0, inputSize - 1);
    final mapY = ((y / frameHeight) * inputSize).round().clamp(0, inputSize - 1);

    // Sample a small region around the point for robustness (3×3 average)
    double sum = 0;
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final sx = (mapX + dx).clamp(0, inputSize - 1);
        final sy = (mapY + dy).clamp(0, inputSize - 1);
        sum += _cachedDepthMap![sy * inputSize + sx];
        count++;
      }
    }

    return sum / count;
  }

  /// Get the estimated distance at a bounding box center.
  ///
  /// Convenience method that calculates the center of a bounding box
  /// and samples the depth map there.
  double? getDistanceForBoundingBox(
    double left, double top, double right, double bottom,
    double frameWidth, double frameHeight,
  ) {
    final centerX = (left + right) / 2;
    final centerY = (top + bottom) / 2;
    return getDistanceAtPoint(centerX, centerY, frameWidth, frameHeight);
  }

  void dispose() {
    unawaited(_isolateInterpreter?.close());
    _isolateInterpreter = null;
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
    _cachedDepthMap = null;
  }
}

/// Core inference logic shared by both entry points.
///
/// Preprocesses the image, runs the MiDaS model, and converts the raw
/// relative inverse-depth output to approximate meters.
Future<Float32List> _runInference(
    IsolateInterpreter interpreter, img.Image resized) async {
  const size = DepthEstimationService.inputSize;

  // Preprocess: Normalize pixels to [0, 1] (MiDaS v2.1 small expects this).
  // getBytes(rgb) returns a flat size*size*3 buffer in the exact order
  // we need — far cheaper than size*size getPixel() Pixel allocations.
  final input = Float32List(1 * size * size * 3);
  final bytes = resized.getBytes(order: img.ChannelOrder.rgb);
  for (int i = 0; i < input.length; i++) {
    input[i] = bytes[i] / 255.0;
  }

  // Reshape input to [1, 256, 256, 3]
  final inputTensor = input.reshape([1, size, size, 3]);

  // Output: [1, 256, 256, 1] — relative inverse depth. Typed buffer +
  // reshape instead of a 256*256 nested-List tree allocated every frame
  // (the old form was a major GC source on the scan hot path).
  final outBuf = Float32List(1 * size * size * 1);
  final output = outBuf.reshape([1, size, size, 1]);

  await interpreter.run(inputTensor, output);

  // Flatten the output and find min/max for normalization
  final flat = Float32List(size * size);
  double minVal = double.infinity;
  double maxVal = double.negativeInfinity;

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final val = output[0][y][x][0];
      flat[y * size + x] = val;
      if (val < minVal) minVal = val;
      if (val > maxVal) maxVal = val;
    }
  }

  // Convert relative inverse-depth to approximate distance in meters.
  //
  // MiDaS outputs higher values for CLOSER objects (inverse depth).
  // 1. Normalize to [0, 1] where 1 = closest, 0 = farthest
  // 2. Convert via range-based formula:
  //    distance = 1 / (A * normalized + B)
  //    where A = 1/minDepth - 1/maxDepth, B = 1/maxDepth
  const minDepth = DepthEstimationService.minDepthMeters;
  const maxDepth = DepthEstimationService.maxDepthMeters;
  const a = (1.0 / minDepth) - (1.0 / maxDepth);
  const b = 1.0 / maxDepth;

  final range = maxVal - minVal;
  if (range < 1e-6) {
    // Flat scene — assume everything is at medium distance
    flat.fillRange(0, flat.length, (minDepth + maxDepth) / 2);
    return flat;
  }

  for (int i = 0; i < flat.length; i++) {
    // Normalize: 1 = closest (was max in inverse depth), 0 = farthest
    final normalized = (flat[i] - minVal) / range;
    // Clamp to avoid division by zero
    final clamped = normalized.clamp(0.01, 1.0);
    // Convert to meters
    flat[i] = (1.0 / (a * clamped + b)).clamp(minDepth, maxDepth);
  }

  return flat;
}
