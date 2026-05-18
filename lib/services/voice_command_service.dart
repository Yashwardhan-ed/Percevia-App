// Voice Command Service
// Parses and executes voice commands for hands-free UX
// Supported commands:
// - "describe" - Short description of the scene
// - "read text" - Read text in the image
// - "recognize" - Start face recognition
// - "register face" - Start face registration
// - "stop" - Stop current operation

enum VoiceCommand {
  describe,
  readText,
  recognize,
  registerFace,
  stop,
  unknown,
}

class VoiceCommandService {
  // Command keyword patterns
  static const Map<VoiceCommand, List<String>> _commandPatterns = {
    VoiceCommand.describe: [
      'describe',
      'describe the scene',
      'tell me what you see',
      'what do you see',
      'what is this',
    ],
    VoiceCommand.readText: [
      'read text',
      'read the text',
      'read',
      'what text',
      'read the writing',
      'ocr',
    ],
    VoiceCommand.recognize: [
      'recognize',
      'recognize face',
      'recognize faces',
      'face recognition',
      'who is this',
      'identify',
      'identify face',
    ],
    VoiceCommand.registerFace: [
      'register face',
      'register',
      'register my face',
      'add face',
      'register new face',
    ],
    VoiceCommand.stop: [
      'stop',
      'stop listening',
      'stop that',
      'cancel',
      'quit',
      'exit',
    ],
  };

  /// Parse voice input and return the matched command
  static VoiceCommand parseCommand(String voiceInput) {
    final normalizedInput = voiceInput.toLowerCase().trim();

    for (final entry in _commandPatterns.entries) {
      for (final pattern in entry.value) {
        // Check for exact match or partial match
        if (normalizedInput == pattern || normalizedInput.contains(pattern)) {
          return entry.key;
        }
      }
    }

    return VoiceCommand.unknown;
  }

  /// Get a user-friendly description of the command
  static String getCommandDescription(VoiceCommand command) {
    switch (command) {
      case VoiceCommand.describe:
        return 'Describe';
      case VoiceCommand.readText:
        return 'Read Text';
      case VoiceCommand.recognize:
        return 'Face Recognition';
      case VoiceCommand.registerFace:
        return 'Register Face';
      case VoiceCommand.stop:
        return 'Stop';
      case VoiceCommand.unknown:
        return 'Unknown Command';
    }
  }

  /// Get audio cue for command recognition
  static String getAudioCue(VoiceCommand command) {
    switch (command) {
      case VoiceCommand.describe:
        return 'Starting description mode. Take a picture to describe the scene.';
      case VoiceCommand.readText:
        return 'Reading text mode activated. Point at text you want to read.';
      case VoiceCommand.recognize:
        return 'Face recognition started. I will announce faces I recognize.';
      case VoiceCommand.registerFace:
        return 'Entering face registration mode.';
      case VoiceCommand.stop:
        return 'Stopping current operation.';
      case VoiceCommand.unknown:
        return 'Sorry, I did not understand that command.';
    }
  }

  /// Check if a command requires the app to be in listening mode
  static bool requiresImage(VoiceCommand command) {
    switch (command) {
      case VoiceCommand.describe:
      case VoiceCommand.readText:
        return true;
      case VoiceCommand.recognize:
      case VoiceCommand.registerFace:
      case VoiceCommand.stop:
      case VoiceCommand.unknown:
        return false;
    }
  }
}
