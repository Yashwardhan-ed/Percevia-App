import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:percevia/models/face_data.dart';

class FaceDetectionService {
  late FaceDetector _faceDetector;
  bool _isInitialized = false;
  CameraDescription? _cameraDescription;

  // Store the last cropped face for local LLM comparison
  List<int>? lastCroppedFaceBytes;

  /// Set the camera description for correct orientation handling.
  /// Must be called before using cropAndAlignFace with CameraImage.
  void setCameraDescription(CameraDescription description) {
    _cameraDescription = description;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    final options = FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.15, // Minimum face size relative to image
    );
    _faceDetector = FaceDetector(options: options);
    _isInitialized = true;
    debugPrint('[FaceDetection] Initialized with accurate mode');
  }

  /// Detects faces and returns pose data from the camera image
  Future<List<PoseData>> detectFaces(CameraImage image) async {
    if (!_isInitialized) await initialize();

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return [];

      final faces = await _faceDetector.processImage(inputImage);
      
      return faces.map((face) => PoseData(
        yaw: face.headEulerAngleY ?? 0,
        pitch: face.headEulerAngleX ?? 0,
        roll: face.headEulerAngleZ ?? 0,
        landmarkCount: face.landmarks.length,
      )).toList();
    } catch (e) {
      debugPrint('Error detecting faces: $e');
      return [];
    }
  }

  /// Crops and aligns face for FaceNet model
  /// Returns aligned image as bytes (112x112)
  Future<List<int>?> cropAndAlignFace(CameraImage cameraImage) async {
    if (!_isInitialized) await initialize();

    try {
      final inputImage = _inputImageFromCameraImage(cameraImage);
      if (inputImage == null) return null;

      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isEmpty) return null;

      // Get the largest face
      final face = faces.reduce((a, b) => 
        (a.boundingBox.width * a.boundingBox.height) > (b.boundingBox.width * b.boundingBox.height) ? a : b
      );

      // Convert camera image to img.Image for cropping
      img.Image? image = _convertCameraImageToImage(cameraImage);
      if (image == null) return null;

      return _cropAndAlignFaceFromImage(image, face);
    } catch (e) {
      debugPrint('[FaceDetection] Error cropping face: $e');
      return null;
    }
  }

  /// Detect and crop face from image bytes (JPEG/PNG)
  /// Returns cropped and aligned face as bytes (112x112) or null if no face detected
  /// Detect and crop face from image bytes (JPEG/PNG)
  /// Returns cropped and aligned face as bytes (112x112) or null if no face detected
  /// Set [bypassQualityCheck] to true during registration to allow angled poses
  Future<List<int>?> detectSingleFace(dynamic imageBytes, {bool bypassQualityCheck = false}) async {
    if (!_isInitialized) await initialize();

    try {
      final bytes = imageBytes is List<int> ? Uint8List.fromList(imageBytes) : imageBytes as Uint8List;
      
      // Create temp file for ML Kit. flush:true so ML Kit's native reader
      // sees the complete file (a non-flushed write can be read partially).
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/temp_face_detect.jpg');
      await file.writeAsBytes(bytes, flush: true);

      final inputImage = InputImage.fromFilePath(file.path);
      final faces = await _faceDetector.processImage(inputImage);
      
      if (faces.isEmpty) {
        debugPrint('[FaceDetection] No face detected in image');
        return null;
      }

      // Get the largest face with best quality
      final face = _selectBestFace(faces);
      
      // Check face quality (skip during registration to allow angled poses)
      if (!bypassQualityCheck && !_isFaceQualityAcceptable(face)) {
        debugPrint('[FaceDetection] Face quality too low (angle/size)');
        return null;
      }

      // Decode original image for cropping. ML Kit's file reader applies the
      // JPEG's EXIF orientation, so its bounding box / landmarks are in
      // upright space. The image package does NOT auto-apply EXIF on decode,
      // so bake it here — otherwise the crop lands off the (rotated) face.
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return null;
      image = img.bakeOrientation(image);

      return _cropAndAlignFaceFromImage(image, face);
    } catch (e) {
      debugPrint('[FaceDetection] Error detecting single face: $e');
      return null;
    }
  }

  /// Select the best face from detected faces
  Face _selectBestFace(List<Face> faces) {
    if (faces.length == 1) return faces.first;
    
    // Score faces based on size and frontality
    Face bestFace = faces.first;
    double bestScore = 0;
    
    for (final face in faces) {
      final size = face.boundingBox.width * face.boundingBox.height;
      final yaw = (face.headEulerAngleY ?? 0).abs();
      final pitch = (face.headEulerAngleX ?? 0).abs();
      
      // Prefer larger, more frontal faces
      // Penalize faces with large yaw/pitch angles
      final angleScore = math.max(0, 1 - (yaw + pitch) / 90);
      final score = size * angleScore;
      
      if (score > bestScore) {
        bestScore = score;
        bestFace = face;
      }
    }
    
    return bestFace;
  }

  /// Check if face pose is acceptable for recognition
  bool _isFaceQualityAcceptable(Face face) {
    final yaw = (face.headEulerAngleY ?? 0).abs();
    final pitch = (face.headEulerAngleX ?? 0).abs();
    
    // Generous limits: registration captures a burst of varied poses, so
    // recognition must still evaluate moderately off-angle frames instead of
    // discarding them (a too-tight gate here was rejecting valid views).
    // Beyond these the face is too profile/tilted for a stable embedding.
    const maxYaw = 50.0;
    const maxPitch = 35.0;
    
    if (yaw > maxYaw || pitch > maxPitch) {
      debugPrint('[FaceDetection] Face angle too extreme: yaw=$yaw, pitch=$pitch');
      return false;
    }
    
    return true;
  }

  /// Crop and align face using landmarks for better recognition
  List<int>? _cropAndAlignFaceFromImage(img.Image image, Face face) {
    final boundingBox = face.boundingBox;
    
    // Get eye landmarks for alignment
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    
    // Calculate face region with proper padding
    // Use more padding for better context (20% on each side)
    const double paddingX = 0.25;
    const double paddingY = 0.30; // More vertical padding for forehead/chin
    
    int x = math.max(0, (boundingBox.left - boundingBox.width * paddingX).toInt());
    int y = math.max(0, (boundingBox.top - boundingBox.height * paddingY).toInt());
    int w = math.min(image.width - x, (boundingBox.width * (1 + 2 * paddingX)).toInt());
    int h = math.min(image.height - y, (boundingBox.height * (1 + 2 * paddingY)).toInt());
    
    // Ensure minimum size
    if (w < 50 || h < 50) {
      debugPrint('[FaceDetection] Face too small: ${w}x$h');
      return null;
    }

    // Crop face region
    img.Image croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);
    
    // If we have eye landmarks, align the face
    if (leftEye != null && rightEye != null) {
      // Convert FaceLandmark positions to math.Point
      final leftEyePoint = math.Point<int>(
        leftEye.position.x.toInt(), 
        leftEye.position.y.toInt(),
      );
      final rightEyePoint = math.Point<int>(
        rightEye.position.x.toInt(), 
        rightEye.position.y.toInt(),
      );
      
      croppedFace = _alignFaceByEyes(
        croppedFace, 
        leftEyePoint, 
        rightEyePoint,
        x, y, // Offset to adjust coordinates
      );
    }

    // Resize to 112x112 (FaceNet/MobileFaceNet standard)
    img.Image resized = img.copyResize(
      croppedFace, 
      width: 112, 
      height: 112,
      interpolation: img.Interpolation.cubic, // Better quality interpolation
    );

    // Store for local LLM verification
    lastCroppedFaceBytes = img.encodePng(resized);
    
    return lastCroppedFaceBytes;
  }

  /// Align face based on eye positions
  /// This helps normalize face orientation for better embedding consistency
  img.Image _alignFaceByEyes(
    img.Image image, 
    math.Point<int> leftEyePos, 
    math.Point<int> rightEyePos,
    int offsetX,
    int offsetY,
  ) {
    // Adjust eye positions relative to cropped image
    final leftEyeX = (leftEyePos.x - offsetX).toDouble();
    final leftEyeY = (leftEyePos.y - offsetY).toDouble();
    final rightEyeX = (rightEyePos.x - offsetX).toDouble();
    final rightEyeY = (rightEyePos.y - offsetY).toDouble();
    
    // Calculate angle between eyes
    final dY = rightEyeY - leftEyeY;
    final dX = rightEyeX - leftEyeX;
    final angle = math.atan2(dY, dX);
    
    // Only rotate if angle is significant (> 2 degrees)
    if (angle.abs() > 0.035) { // ~2 degrees in radians
      // Convert to degrees for the rotation function
      final angleDegrees = angle * 180 / math.pi;
      
      // Rotate the image to align eyes horizontally
      return img.copyRotate(
        image, 
        angle: -angleDegrees,
        interpolation: img.Interpolation.cubic,
      );
    }
    
    return image;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_cameraDescription == null) {
      debugPrint('[FaceDetection] WARNING: No camera description set, using default orientation');
    }
    final sensorOrientation = _cameraDescription?.sensorOrientation ?? 90;
    final rotations = {
      90: InputImageRotation.rotation90deg,
      180: InputImageRotation.rotation180deg,
      270: InputImageRotation.rotation270deg,
      0: InputImageRotation.rotation0deg,
    };
    final rotation = rotations[sensorOrientation] ?? InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;
    
    // Concatenate planes for NV21 (Android default)
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane p in image.planes) {
      allBytes.putUint8List(p.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  /// Convert CameraImage to img.Image
  img.Image? _convertCameraImageToImage(CameraImage cameraImage) {
    try {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        return _convertYUV420(cameraImage);
      } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        return img.Image.fromBytes(
          width: cameraImage.width,
          height: cameraImage.height,
          bytes: cameraImage.planes[0].bytes.buffer,
          format: img.Format.uint8,
        );
      }
      return null;
    } catch (e) {
      debugPrint('Error converting camera image: $e');
      return null;
    }
  }

  /// Convert YUV420 format to RGB
  img.Image _convertYUV420(CameraImage image) {
    final width = image.width;
    final height = image.height;

    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    final imgData = img.Image(width: width, height: height);

    for (int h = 0; h < height; h++) {
      int uvh = (h / 2).floor();
      for (int w = 0; w < width; w++) {
        int uvw = (w / 2).floor();

        final yIndex = h * image.planes[0].bytesPerRow + w;
        final uIndex = uvh * uvRowStride + uvw * uvPixelStride;
        final vIndex = uvh * image.planes[2].bytesPerRow + uvw * (image.planes[2].bytesPerPixel ?? 1);

        final y = image.planes[0].bytes[yIndex];
        final u = image.planes[1].bytes[uIndex];
        final v = image.planes[2].bytes[vIndex];

        final rgb = _yuv2rgb(y, u, v);
        imgData.setPixelRgba(w, h, rgb.r, rgb.g, rgb.b, rgb.a);
      }
    }
    return imgData;
  }

  /// Convert YUV to RGB
  ({int r, int g, int b, int a}) _yuv2rgb(int y, int u, int v) {
    int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
    int g = (y - 0.34414 * (u - 128) - 0.71414 * (v - 128))
        .round()
        .clamp(0, 255);
    int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);
    return (r: r, g: g, b: b, a: 255);
  }

  void dispose() {
    if (_isInitialized) {
      _faceDetector.close();
      _isInitialized = false;
    }
  }
}
