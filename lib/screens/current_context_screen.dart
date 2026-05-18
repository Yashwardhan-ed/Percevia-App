import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percevia/services/output_language_service.dart';
import 'package:percevia/services/settings_service.dart';

class CurrentContextScreen extends StatefulWidget {
  final List<Map<String, dynamic>> chatContext;
  final VoidCallback onClearContext;

  const CurrentContextScreen({
    super.key,
    required this.chatContext,
    required this.onClearContext,
  });

  @override
  State<CurrentContextScreen> createState() => _CurrentContextScreenState();
}

class _CurrentContextScreenState extends State<CurrentContextScreen> {
  final FlutterTts _tts = FlutterTts();
  final SettingsService _settingsService = SettingsService();
  String _outputLanguage = OutputLanguageService.defaultLanguage;

  @override
  void initState() {
    super.initState();
    unawaited(_setupAndAnnounce());
  }

  Future<void> _setupAndAnnounce() async {
    await _settingsService.initialize();
    final rate = await _settingsService.getSpeechRate();
    _outputLanguage = await _settingsService.getOutputLanguage();
    final languageCode = await OutputLanguageService.resolveTtsLanguageCode(
      _tts,
      _outputLanguage,
    );
    await _tts.setLanguage(languageCode);
    await _tts.setSpeechRate(_settingsService.toEngineSpeechRate(rate));

    final summary = OutputLanguageService.recentContextSummary(
      _outputLanguage,
      widget.chatContext.length,
    );

    await _tts.stop();
    await _tts.speak(summary);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Recent Context',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        actions: [
          if (widget.chatContext.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              tooltip: 'Clear Context',
              onPressed: () {
                widget.onClearContext();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Context cleared'),
                    backgroundColor: Colors.green,
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
        ],
      ),
      body: widget.chatContext.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  'No recent conversation context. Try describing an image or asking a question first.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: Colors.white70,
                    fontSize: 18,
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: widget.chatContext.length,
              itemBuilder: (context, index) {
                final message = widget.chatContext[index];
                final isUser = message['role'] == 'user';
                
                String textContent = "";
                Uint8List? imageBytes;

                if (message['parts'] != null && message['parts'] is List) {
                  for (var part in message['parts']) {
                    if (part['text'] != null) {
                      textContent += part['text'] + "\n";
                    }
                    if (part['inline_data'] != null && part['inline_data']['data'] != null) {
                      try {
                        imageBytes = base64Decode(part['inline_data']['data']);
                      } catch (e) {
                         debugPrint("Could not decode image in context view: $e");
                      }
                    }
                  }
                }

                return _buildMessageBubble(
                  isUser: isUser,
                  text: textContent.trim(),
                  imageBytes: imageBytes,
                );
              },
            ),
    );
  }

  Widget _buildMessageBubble({
    required bool isUser,
    required String text,
    Uint8List? imageBytes,
  }) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16.0),
        padding: const EdgeInsets.all(16.0),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF1E1E1E) : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(16.0),
          border: Border.all(
            color: isUser ? Colors.white30 : const Color(0xFF7FE5E0).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUser ? 'You' : 'Percevia',
              style: GoogleFonts.inter(
                color: isUser ? Colors.white70 : const Color(0xFF7FE5E0),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (imageBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: Image.memory(
                  imageBytes,
                  width: 200,
                  height: 150,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (text.isNotEmpty)
              Text(
                text,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
