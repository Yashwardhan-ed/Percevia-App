import 'package:hive_flutter/hive_flutter.dart';
import 'package:percevia/models/saved_response.dart';

class SavedResponseService {
  static const String _boxName = 'saved_responses';
  late Box _box;
  bool _isInitialized = false;

  /// Initialize Hive and open the box
  Future<void> initialize() async {
    if (_isInitialized) return;

    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _isInitialized = true;
  }

  /// Save a new response
  Future<void> saveResponse(SavedResponse response) async {
    if (!_isInitialized) await initialize();
    await _box.put(response.id, response.toMap());
  }

  /// Get all saved responses, ordered by newest first
  Future<List<SavedResponse>> getAllResponses() async {
    if (!_isInitialized) await initialize();

    final List<SavedResponse> responses = [];
    for (var i = 0; i < _box.length; i++) {
      final item = _box.getAt(i);
      if (item != null && item is Map) {
        responses.add(SavedResponse.fromMap(item));
      }
    }

    // Sort by timestamp descending (newest first)
    responses.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return responses;
  }

  /// Delete a saved response by ID
  Future<void> deleteResponse(String id) async {
    if (!_isInitialized) await initialize();
    await _box.delete(id);
  }

  /// Clear all saved responses
  Future<void> clearAll() async {
    if (!_isInitialized) await initialize();
    await _box.clear();
  }
}
