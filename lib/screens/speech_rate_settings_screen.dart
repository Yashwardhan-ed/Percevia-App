import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percevia/services/output_language_service.dart';
import '../services/settings_service.dart';

class SpeechRateSettingsScreen extends StatefulWidget {
  const SpeechRateSettingsScreen({
    super.key,
    required this.flutterTts,
  });

  final FlutterTts flutterTts;

  @override
  State<SpeechRateSettingsScreen> createState() =>
      _SpeechRateSettingsScreenState();
}

class _SpeechRateSettingsScreenState extends State<SpeechRateSettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  double _currentRate = 1.0;
  bool _isLoading = true;
  String _outputLanguage = OutputLanguageService.defaultLanguage;

  @override
  void initState() {
    super.initState();
    _loadCurrentRate();
  }

  Future<void> _loadCurrentRate() async {
    try {
      final rate = await _settingsService.getSpeechRate();
      final outputLanguage = await _settingsService.getOutputLanguage();
      setState(() {
        _currentRate = rate;
        _outputLanguage = outputLanguage;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _currentRate = 1.0;
        _outputLanguage = OutputLanguageService.defaultLanguage;
        _isLoading = false;
      });
      debugPrint('Error loading speech rate: $e');
    }
  }

  Future<void> _updateRate(double newRate) async {
    setState(() {
      _currentRate = newRate;
    });
    
    // Update TTS immediately for preview using calibrated engine rate
    await widget.flutterTts.setSpeechRate(
      _settingsService.toEngineSpeechRate(newRate),
    );
    
    // Save to storage
    await _settingsService.setSpeechRate(newRate);
    
    // Haptic feedback
    HapticFeedback.selectionClick();
  }

  Future<void> _testSpeech() async {
    HapticFeedback.mediumImpact();
    _outputLanguage = await _settingsService.getOutputLanguage();
    await widget.flutterTts.speak(
      OutputLanguageService.speechRatePreview(
        _outputLanguage,
        _currentRate.toStringAsFixed(1),
      ),
    );
  }

  Future<void> _resetToDefault() async {
    HapticFeedback.mediumImpact();
    final defaultRate = _settingsService.defaultSpeechRate;
    await _updateRate(defaultRate);
    _outputLanguage = await _settingsService.getOutputLanguage();
    await widget.flutterTts.speak(
      OutputLanguageService.speechRateReset(_outputLanguage),
    );
  }

  String _getRateLabel() {
    if (_currentRate < 0.9) return 'Slower';
    if (_currentRate < 1.1) return 'Normal';
    if (_currentRate < 1.5) return 'Fast';
    return 'Very Fast';
  }

  Widget _buildPresetButton(String label, double rate) {
    final isSelected = (_currentRate - rate).abs() < 0.01;
    
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: isSelected ? Colors.white : Colors.black.withValues(alpha: 0.4),
            foregroundColor: isSelected ? Colors.black : Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isSelected ? Colors.white : Colors.white30,
                width: isSelected ? 3 : 1,
              ),
            ),
            elevation: isSelected ? 4 : 0,
          ),
          onPressed: () => _updateRate(rate),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
          onPressed: () {
            HapticFeedback.mediumImpact();
            Navigator.pop(context);
          },
        ),
        title: Text(
          'Speech Rate',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40),
                    
                    // Current rate display
                    Center(
                      child: Column(
                        children: [
                          Text(
                            _currentRate.toStringAsFixed(2),
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 72,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _getRateLabel(),
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontSize: 24,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
    const SizedBox(height: 60),
                    
                    // Preset speed buttons
                    Column(
                      children: [
                        Text(
                          'Select Speech Speed',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildPresetButton('1x', 1.0),
                            _buildPresetButton('1.25x', 1.25),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                              _buildPresetButton('1.5x', 1.5),
                            _buildPresetButton('2x', 2.0),
                          ],
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 60),
                    
                    // Test speech button
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      onPressed: _testSpeech,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.volume_up, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Test Speech',
                            style: GoogleFonts.inter(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Reset button
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _resetToDefault,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.refresh, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Reset to Default',
                            style: GoogleFonts.inter(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const Spacer(),
                    
                    // Info text
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Select your preferred speech speed. '
                        'Lower speeds (0.8x) are clearer and easier to follow. '
                        'Higher speeds (2x) are faster. '
                        'You can try each option with the Test Speech button.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          color: Colors.white70,
                          fontSize: 16,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
