import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:percevia/models/face_data.dart';

class FaceStorageService {
  static const String _boxName = 'faces';
  late Box _box;
  bool _isInitialized = false;

  /// Initialize Hive and open the box
  Future<void> initialize() async {
    if (_isInitialized) return;

    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _isInitialized = true;
  }

  /// Register a new person with embeddings
  Future<void> registerPerson(FacePerson person) async {
    if (!_isInitialized) await initialize();

    final map = person.toMap();
    debugPrint('[Storage] Saving person: ${person.name}');
    debugPrint('[Storage] Embeddings count: ${person.embeddings.length}');
    debugPrint('[Storage] First embedding length: ${person.embeddings.isNotEmpty ? person.embeddings[0].length : 0}');
    debugPrint('[Storage] Map embeddings type: ${map['embeddings'].runtimeType}');
    debugPrint('[Storage] Map embeddings length: ${(map['embeddings'] as List).length}');
    
    await _box.put(person.id, map);
    
    // Verify it was saved correctly
    final retrieved = _box.get(person.id);
    if (retrieved != null && retrieved is Map) {
      final embeddingsList = retrieved['embeddings'];
      debugPrint('[Storage] Verified saved - embeddings length: ${(embeddingsList as List).length}');
    }
  }

  /// Get a person by ID
  Future<FacePerson?> getPerson(String id) async {
    if (!_isInitialized) await initialize();

    final data = _box.get(id);
    if (data == null || data is! Map) return null;

    // Convert dynamic map to Map<String, dynamic>
    final convertedMap = Map<String, dynamic>.from(data);
    return FacePerson.fromMap(convertedMap);
  }

  /// Get all registered persons
  Future<List<FacePerson>> getAllPersons() async {
    if (!_isInitialized) await initialize();

    final persons = <FacePerson>[];
    debugPrint('[Storage] Total keys in box: ${_box.keys.length}');
    
    for (final key in _box.keys) {
      try {
        final data = _box.get(key);
        if (data != null && data is Map) {
          // Convert dynamic map to Map<String, dynamic>
          final convertedMap = Map<String, dynamic>.from(data);
          final person = FacePerson.fromMap(convertedMap);
          
          // Skip persons with no embeddings (corrupted/old records)
          if (person.embeddings.isEmpty) {
            debugPrint('[Storage] Skipping ${person.name} (ID: $key) - has 0 embeddings');
            continue;
          }
          
          persons.add(person);
          debugPrint('[Storage] Successfully loaded person: ${person.name} with ${person.embeddings.length} embeddings');
        }
      } catch (e, stackTrace) {
        debugPrint('[Storage] Error converting person data for key $key: $e');
        debugPrint('[Storage] Stack trace: $stackTrace');
      }
    }
    debugPrint('[Storage] Total persons loaded: ${persons.length}');
    return persons;
  }

  /// Update an existing person
  Future<void> updatePerson(FacePerson person) async {
    if (!_isInitialized) await initialize();

    await _box.put(person.id, person.toMap());
  }

  /// Delete a person
  Future<void> deletePerson(String id) async {
    if (!_isInitialized) await initialize();

    await _box.delete(id);
  }

  /// Clear all data
  Future<void> clear() async {
    if (!_isInitialized) await initialize();

    await _box.clear();
  }

  /// Clean up corrupted records (persons with no embeddings)
  Future<int> cleanupCorruptedRecords() async {
    if (!_isInitialized) await initialize();

    int deletedCount = 0;
    final keysToDelete = <dynamic>[];
    
    for (final key in _box.keys) {
      try {
        final data = _box.get(key);
        if (data != null && data is Map) {
          final convertedMap = Map<String, dynamic>.from(data);
          final embeddingsList = convertedMap['embeddings'];
          if (embeddingsList == null || (embeddingsList as List).isEmpty) {
            keysToDelete.add(key);
            debugPrint('[Storage] Marked for deletion: ${convertedMap['name']} (ID: $key) - no embeddings');
          }
        }
      } catch (e) {
        debugPrint('[Storage] Error checking key $key, marking for deletion: $e');
        keysToDelete.add(key);
      }
    }
    
    for (final key in keysToDelete) {
      await _box.delete(key);
      deletedCount++;
    }
    
    debugPrint('[Storage] Cleanup complete: deleted $deletedCount corrupted records');
    return deletedCount;
  }

  void dispose() {
    // Box will be closed when app closes
  }
}
