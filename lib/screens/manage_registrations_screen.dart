import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percevia/services/face_storage_service.dart';
import 'package:percevia/services/output_language_service.dart';
import 'package:percevia/services/settings_service.dart';
import 'package:percevia/models/face_data.dart';

class ManageRegistrationsScreen extends StatefulWidget {
  const ManageRegistrationsScreen({super.key});

  @override
  State<ManageRegistrationsScreen> createState() => _ManageRegistrationsScreenState();
}

class _ManageRegistrationsScreenState extends State<ManageRegistrationsScreen> {
  final FaceStorageService _storageService = FaceStorageService();
  final FlutterTts _tts = FlutterTts();
  final SettingsService _settingsService = SettingsService();
  List<FacePerson> _persons = [];
  bool _isLoading = true;
  bool _isTtsReady = false;
  String _outputLanguage = OutputLanguageService.defaultLanguage;

  @override
  void initState() {
    super.initState();
    _setupTts();
    _loadRegistrations();
  }

  Future<void> _setupTts() async {
    await _settingsService.initialize();
    final rate = await _settingsService.getSpeechRate();
    _outputLanguage = await _settingsService.getOutputLanguage();
    final languageCode = await OutputLanguageService.resolveTtsLanguageCode(
      _tts,
      _outputLanguage,
    );
    await _tts.setLanguage(languageCode);
    await _tts.setSpeechRate(_settingsService.toEngineSpeechRate(rate));
    _isTtsReady = true;
    if (!_isLoading) {
      unawaited(_announceScreen(_persons));
    }
  }

  Future<void> _loadRegistrations() async {
    setState(() => _isLoading = true);
    await _storageService.initialize();
    final persons = await _storageService.getAllPersons();
    setState(() {
      _persons = persons;
      _isLoading = false;
    });
    unawaited(_announceScreen(persons));
  }

  Future<void> _announceScreen(List<FacePerson> persons) async {
    if (!_isTtsReady) return;
    _outputLanguage = await _settingsService.getOutputLanguage();
    final summary = OutputLanguageService.manageRegistrationsSummary(
      _outputLanguage,
      persons.length,
    );
    await _tts.stop();
    await _tts.speak(summary);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _deletePerson(FacePerson person) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'Delete Registration',
          style: GoogleFonts.inter(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to delete ${person.name}?',
          style: GoogleFonts.inter(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: GoogleFonts.inter(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _storageService.deletePerson(person.id);
      HapticFeedback.mediumImpact();
      _loadRegistrations();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${person.name} deleted',
              style: GoogleFonts.inter(color: Colors.white),
            ),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _cleanupCorruptedRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'Clean Up Database',
          style: GoogleFonts.inter(color: Colors.white),
        ),
        content: Text(
          'This will remove all corrupted records (persons with no embeddings). Continue?',
          style: GoogleFonts.inter(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Clean Up',
              style: GoogleFonts.inter(color: Colors.orange),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final deletedCount = await _storageService.cleanupCorruptedRecords();
        HapticFeedback.mediumImpact();
        _loadRegistrations();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cleaned up $deletedCount corrupted records',
                style: GoogleFonts.inter(color: Colors.white),
              ),
              backgroundColor: Colors.orange[700],
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Error during cleanup: $e',
                style: GoogleFonts.inter(color: Colors.white),
              ),
              backgroundColor: Colors.red[700],
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Manage Registrations',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services, color: Colors.orange),
            tooltip: 'Clean up corrupted records',
            onPressed: _cleanupCorruptedRecords,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : _persons.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.face_retouching_natural_outlined,
                        size: 80,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'No registrations yet',
                        style: GoogleFonts.inter(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _persons.length,
                  itemBuilder: (context, index) {
                    final person = _persons[index];
                    return Card(
                      color: Colors.grey[900],
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue[700],
                          child: Text(
                            person.name[0].toUpperCase(),
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          person.name,
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${person.embeddings.length} embeddings • Registered ${_formatDate(person.createdAt)}',
                          style: GoogleFonts.inter(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () => _deletePerson(person),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays == 0) {
      return 'today';
    } else if (difference.inDays == 1) {
      return 'yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
