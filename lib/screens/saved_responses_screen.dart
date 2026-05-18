import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:percevia/models/saved_response.dart';
import 'package:percevia/services/output_language_service.dart';
import 'package:percevia/services/saved_response_service.dart';
import 'package:percevia/services/settings_service.dart';

class SavedResponsesScreen extends StatefulWidget {
  const SavedResponsesScreen({super.key});

  @override
  State<SavedResponsesScreen> createState() => _SavedResponsesScreenState();
}

class _SavedResponsesScreenState extends State<SavedResponsesScreen> {
  final SavedResponseService _service = SavedResponseService();
  final FlutterTts _flutterTts = FlutterTts();
  final SettingsService _settingsService = SettingsService();

  List<SavedResponse> _responses = [];
  bool _isLoading = true;
  String? _currentlyPlayingId;
  String _outputLanguage = OutputLanguageService.defaultLanguage;

  @override
  void initState() {
    super.initState();
    _initServices();
    _setupTts();
  }

  Future<void> _initServices() async {
    await _service.initialize();
    await _settingsService.initialize();
    _loadResponses();
  }

  Future<void> _setupTts() async {
    await _settingsService.initialize();
    _outputLanguage = await _settingsService.getOutputLanguage();
    final languageCode = await OutputLanguageService.resolveTtsLanguageCode(
      _flutterTts,
      _outputLanguage,
    );

    await _flutterTts.setLanguage(languageCode);
    await _flutterTts.awaitSpeakCompletion(true);
    
    _flutterTts.setCompletionHandler(() {
      if (mounted) {
        setState(() {
          _currentlyPlayingId = null;
        });
      }
    });

    _flutterTts.setCancelHandler(() {
      if (mounted) {
        setState(() {
          _currentlyPlayingId = null;
        });
      }
    });
  }

  Future<void> _loadResponses() async {
    setState(() => _isLoading = true);
    final responses = await _service.getAllResponses();
    if (mounted) {
      setState(() {
        _responses = responses;
        _isLoading = false;
      });
    }
    await _announceHistoryScreen(responses);
  }

  Future<void> _announceHistoryScreen(List<SavedResponse> responses) async {
    _outputLanguage = await _settingsService.getOutputLanguage();
    final languageCode = await OutputLanguageService.resolveTtsLanguageCode(
      _flutterTts,
      _outputLanguage,
    );
    final speechRate = await _settingsService.getSpeechRate();
    await _flutterTts.setLanguage(languageCode);
    await _flutterTts.setSpeechRate(_settingsService.toEngineSpeechRate(speechRate));
    final summary = OutputLanguageService.historySummary(
      _outputLanguage,
      responses.length,
    );
    await _flutterTts.stop();
    await _flutterTts.speak(summary);
  }

  Future<void> _playResponse(SavedResponse response) async {
    if (_currentlyPlayingId == response.id) {
      // Pause/Stop
      await _flutterTts.stop();
      setState(() {
        _currentlyPlayingId = null;
      });
    } else {
      // Stop anything that is playing currently
      if (_currentlyPlayingId != null) {
        await _flutterTts.stop();
      }
      
      setState(() {
        _currentlyPlayingId = response.id;
      });

      final speechRate = await _settingsService.getSpeechRate();
      await _flutterTts.setSpeechRate(
        _settingsService.toEngineSpeechRate(speechRate),
      );
      
      await _flutterTts.speak(response.fullText);
    }
  }

  Future<void> _deleteResponse(String id) async {
    if (_currentlyPlayingId == id) {
      await _flutterTts.stop();
    }
    await _service.deleteResponse(id);
    _loadResponses();
  }

  @override
  void dispose() {
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('History', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _responses.isEmpty
              ? const Center(
                  child: Text(
                    "No saved responses yet.",
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  itemCount: _responses.length,
                  itemBuilder: (context, index) {
                    final response = _responses[index];
                    final isPlaying = _currentlyPlayingId == response.id;

                    // Format timestamp
                    final date = response.timestamp;
                    final timeString = "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} ${date.day}/${date.month}";

                    return Card(
                      color: Colors.grey[900],
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ListTile(
                        onTap: () => _playResponse(response),
                        title: Text(
                          response.title,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          timeString,
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                                color: isPlaying ? Colors.blue : Colors.white,
                                size: 32,
                              ),
                              onPressed: () => _playResponse(response),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () => _deleteResponse(response.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
