import 'package:hive_flutter/hive_flutter.dart';

/// Settings Service
/// Stores and retrieves user preferences including speech rate
class SettingsService {
  static const String _boxName = 'settings';
  static const String _speechRateKey = 'speechRate';
  static const String _outputLanguageKey = 'outputLanguage';
  static const String _llmRoutingModeKey = 'llmRoutingMode';
  static const double _defaultSpeechRate = 1.0;
  static const String _defaultOutputLanguage = 'english';
  static const String _defaultLlmRoutingMode = 'local_only';
  static const double _minSpeechRate = 0.8;
  static const double _maxSpeechRate = 2.0;
  static const double _engineRateMultiplier = 0.55;
  static const double _minEngineSpeechRate = 0.45;
  static const double _maxEngineSpeechRate = 1.0;
  
  late Box _box;
  bool _isInitialized = false;

  /// Initialize Hive and open the settings box
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Hive.initFlutter() should already be called by face storage,
    // but it's safe to call multiple times
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _isInitialized = true;
  }

  /// Get the saved speech rate
  /// Returns default rate (1.0) if not set
  Future<double> getSpeechRate() async {
    if (!_isInitialized) await initialize();
    
    final rate = _box.get(_speechRateKey, defaultValue: _defaultSpeechRate);
    return rate is double ? rate : _defaultSpeechRate;
  }

  /// Get the saved output language key.
  /// Supported values: english, hindi, marwari
  Future<String> getOutputLanguage() async {
    if (!_isInitialized) await initialize();

    final value = _box.get(_outputLanguageKey, defaultValue: _defaultOutputLanguage);
    return value is String && value.isNotEmpty ? value : _defaultOutputLanguage;
  }

  /// Get LLM routing mode.
  /// Supported values: local_only, local_preferred_remote_fallback
  Future<String> getLlmRoutingMode() async {
    if (!_isInitialized) await initialize();

    final value = _box.get(_llmRoutingModeKey, defaultValue: _defaultLlmRoutingMode);
    if (value is! String || value.isEmpty) return _defaultLlmRoutingMode;
    return (value == 'local_preferred_remote_fallback')
        ? value
        : _defaultLlmRoutingMode;
  }

  /// Save the speech rate
  /// Valid UI range: 0.8 to 2.0
  Future<void> setSpeechRate(double rate) async {
    if (!_isInitialized) await initialize();
    
    // Clamp the rate between valid bounds
    final clampedRate = rate.clamp(_minSpeechRate, _maxSpeechRate);
    await _box.put(_speechRateKey, clampedRate);
  }

  /// Save output language key.
  Future<void> setOutputLanguage(String language) async {
    if (!_isInitialized) await initialize();

    const supported = {'english', 'hindi', 'marwari'};
    final normalized = language.trim().toLowerCase();
    final value = supported.contains(normalized)
        ? normalized
        : _defaultOutputLanguage;
    await _box.put(_outputLanguageKey, value);
  }

  /// Save llm routing mode.
  Future<void> setLlmRoutingMode(String mode) async {
    if (!_isInitialized) await initialize();
    final normalized = mode.trim().toLowerCase();
    final value = normalized == 'local_preferred_remote_fallback'
        ? normalized
        : _defaultLlmRoutingMode;
    await _box.put(_llmRoutingModeKey, value);
  }

  /// Convert UI rate into a calibrated engine rate.
  ///
  /// Samsung TTS voices can sound faster than expected, so we scale down
  /// the actual engine rate while preserving the same UI presets.
  double toEngineSpeechRate(double uiRate) {
    final clampedUiRate = uiRate.clamp(_minSpeechRate, _maxSpeechRate).toDouble();
    return (clampedUiRate * _engineRateMultiplier)
        .clamp(_minEngineSpeechRate, _maxEngineSpeechRate)
        .toDouble();
  }

  /// Reset speech rate to default
  Future<void> resetSpeechRate() async {
    await setSpeechRate(_defaultSpeechRate);
  }

  /// Reset output language to default (English).
  Future<void> resetOutputLanguage() async {
    await setOutputLanguage(_defaultOutputLanguage);
  }

  /// Get the default speech rate value
  double get defaultSpeechRate => _defaultSpeechRate;

  /// Get the default output language key.
  String get defaultOutputLanguage => _defaultOutputLanguage;

  /// Get the default llm routing mode.
  String get defaultLlmRoutingMode => _defaultLlmRoutingMode;
}
