import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percevia/services/face_detection_service.dart';
import 'package:percevia/services/facenet_service.dart';
import 'package:percevia/services/face_storage_service.dart';
import 'package:percevia/services/output_language_service.dart';
import 'package:percevia/services/registration_controller.dart';
import 'package:percevia/services/settings_service.dart';

class FaceRegistrationScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const FaceRegistrationScreen({
    required this.cameras,
    super.key,
  });

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen> {
  late CameraController _cameraController;
  late Future<void> _initializeControllerFuture;
  late RegistrationController _registrationController;
  late FaceDetectionService _faceDetectionService;
  late FaceNetService _faceNetService;
  late FaceStorageService _storageService;
  late FlutterTts _tts;
  final SettingsService _settingsService = SettingsService();
  String _outputLanguage = OutputLanguageService.defaultLanguage;

  final TextEditingController _nameController = TextEditingController();
  bool _isRegistering = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  void _initializeServices() async {
    _tts = FlutterTts();

    await _settingsService.initialize();
    _outputLanguage = await _settingsService.getOutputLanguage();
    final speechRate = await _settingsService.getSpeechRate();
    final languageCode = await OutputLanguageService.resolveTtsLanguageCode(
      _tts,
      _outputLanguage,
    );

    await _tts.setLanguage(languageCode);
    await _tts.setSpeechRate(_settingsService.toEngineSpeechRate(speechRate));

    _faceDetectionService = FaceDetectionService();
    _faceNetService = FaceNetService();
    _storageService = FaceStorageService();
    
    // Initialize storage service before use
    await _storageService.initialize();

    // Set the actual camera description for correct ML Kit orientation
    _faceDetectionService.setCameraDescription(widget.cameras[0]);

    _registrationController = RegistrationController(
      tts: _tts,
      faceDetectionService: _faceDetectionService,
      faceNetService: _faceNetService,
      storageService: _storageService,
      outputLanguage: _outputLanguage,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );

    _cameraController = CameraController(
      widget.cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
    );

    _initializeControllerFuture = _cameraController.initialize().then((_) {
      if (mounted) {
        setState(() {});
      }
    }).catchError((e) {
      debugPrint('Camera initialization error: $e');
    });
  }

  void _startRegistration() async {
    try {
      setState(() {
        _isRegistering = true;
      });
      await _registrationController.startRegistration();
    } catch (e) {
      debugPrint('Error starting registration: $e');
      setState(() {
        _isRegistering = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error starting registration')),
        );
      }
    }
  }

  void _captureFrame() async {
    try {
      // Take a picture directly
      final image = await _cameraController.takePicture();
      
      // Read the image file as bytes
      final bytes = await image.readAsBytes();
      
      if (!mounted) return;
      setState(() {});
      
      // Process the captured image to get aligned face
      // Bypass quality check during registration to allow angled poses (left, right, up, down)
      final alignedFace = await _faceDetectionService.detectSingleFace(bytes.toList(), bypassQualityCheck: true);
      
      if (!mounted) return;
      if (alignedFace == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No face detected. Try again.')),
        );
        return;
      }
      
      // Generate embedding from aligned face
      final embedding = await _registrationController.faceNetService.getEmbedding(
        alignedFace,
      );
      
      if (!mounted) return;
      if (embedding.isNotEmpty) {
        // Add to collected embeddings
        _registrationController.collectedEmbeddings.add(embedding);
        
        // Store the first frontal face for local Gemma comparison
        if (_registrationController.embeddingCount == 1) {
          _registrationController.setStoredFaceBytes(alignedFace);
        }
        
        // Move to next step
        await _registrationController.speakCue('Captured!');
        if (!mounted) return;
        _registrationController.moveToNextStep();
        
        setState(() {});
        
        // Show success feedback
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Captured! ${_registrationController.embeddingCount}/6',
            ),
            duration: const Duration(milliseconds: 800),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to process face. Try again.')),
        );
      }
    } catch (e) {
      debugPrint('Error capturing frame: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error capturing frame')),
        );
      }
    }
  }

  void _cancelRegistration() {
    _registrationController.cancel();
    setState(() {
      _isRegistering = false;
    });
  }

  void _completeRegistration() async {
    if (_registrationController.currentStep == RegistrationStep.success) {
      _showNameInputDialog();
    }
  }

  void _showNameInputDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            'Name this face',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'Enter person\'s name',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _saveFace();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveFace() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a name')),
      );
      return;
    }

    final success = await _registrationController.completeRegistration(
      _nameController.text.trim(),
    );

    if (!mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Face registered successfully!')),
      );
      _nameController.clear();
      _registrationController.cancel();
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        Navigator.pop(context);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save face')),
      );
    }
  }

  @override
  void dispose() {
    // Must use unawaited for async cleanup in dispose
    // The camera must be cleaned up before other resources
    unawaited(_cleanupCamera());
    
    _registrationController.dispose();
    _faceDetectionService.dispose();
    _faceNetService.dispose();
    _nameController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _cleanupCamera() async {
    try {
      // CRITICAL: Stop the image stream BEFORE disposing the controller
      if (_cameraController.value.isStreamingImages) {
        await _cameraController.stopImageStream();
      }
      
      // Only dispose if initialized
      if (_cameraController.value.isInitialized) {
        await _cameraController.dispose();
      }
    } catch (e) {
      debugPrint('Error during camera cleanup: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (_isRegistering) {
          _cancelRegistration();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Face Registration'),
          backgroundColor: Colors.black,
          elevation: 0,
        ),
        body: FutureBuilder<void>(
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done) {
              return Stack(
                children: [
                  // Camera preview
                  SizedBox.expand(
                    child: CameraPreview(_cameraController),
                  ),
                  // Overlay with pose guidance
                  _buildPoseOverlay(),
                  // Bottom controls
                  if (!_isRegistering) _buildStartButton(),
                  if (_isRegistering) _buildRegistrationControls(),
                ],
              );
            } else {
              return const Center(child: CircularProgressIndicator());
            }
          },
        ),
      ),
    );
  }

  Widget _buildPoseOverlay() {
    if (!_isRegistering) {
      return Positioned(
        top: 50,
        left: 20,
        right: 20,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'Click "Start" to begin face registration\n\n'
            'You will be guided through:\n'
            '• Face front\n'
            '• Turn left\n'
            '• Turn right\n'
            '• Look up\n'
            '• Look down\n'
            '• Smile\n\n'
            'Position yourself and tap "Capture" for each pose.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: 20,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Column(
          children: [
            // Step indicator
            Text(
              _getStepText(_registrationController.currentStep),
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // Progress
            Text(
              'Captured: ${_registrationController.embeddingCount}/6',
              style: GoogleFonts.inter(
                color: Colors.greenAccent,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            // Instructions
            Text(
              'Position your face and tap the Capture button below',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getStepText(RegistrationStep step) {
    switch (step) {
      case RegistrationStep.idle:
        return 'Ready to register';
      case RegistrationStep.step1Front:
        return 'Step 1: Face the camera';
      case RegistrationStep.step2Left:
        return 'Step 2: Turn left';
      case RegistrationStep.step3Right:
        return 'Step 3: Turn right';
      case RegistrationStep.step4Up:
        return 'Step 4: Look up';
      case RegistrationStep.step5Down:
        return 'Step 5: Look down';
      case RegistrationStep.step6Smile:
        return 'Step 6: Smile';
      case RegistrationStep.processing:
        return 'Processing...';
      case RegistrationStep.success:
        return 'Registration Complete!';
      case RegistrationStep.error:
        return 'Error occurred';
    }
  }

  Widget _buildStartButton() {
    return Positioned(
      bottom: 30,
      left: 20,
      right: 20,
      child: ElevatedButton(
        onPressed: _startRegistration,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          'Start Registration',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildRegistrationControls() {
    return Positioned(
      bottom: 30,
      left: 20,
      right: 20,
      child: Column(
        children: [
          if (_registrationController.currentStep == RegistrationStep.processing)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (_registrationController.currentStep == RegistrationStep.success)
            ElevatedButton(
              onPressed: _completeRegistration,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Continue',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (_registrationController.currentStep != RegistrationStep.success &&
              _registrationController.currentStep != RegistrationStep.idle &&
              _registrationController.currentStep != RegistrationStep.processing)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _captureFrame,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Capture (${_registrationController.embeddingCount}/6)',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _cancelRegistration,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

