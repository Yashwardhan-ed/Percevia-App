import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

class FacePerson {
  final String id;
  final String name;
  final List<List<double>> embeddings; // Multiple embeddings for better matching
  final List<double>? masterEmbedding; // Averaged embedding
  final DateTime createdAt;
  final int captureCount;
  
  // Local LLM verification fields for hybrid recognition
  final String? faceDescription; // Textual description of face features
  final List<int>? storedFaceBytes; // Representative face image for local LLM comparison
  
  // Model versioning - track which model was used to generate embeddings
  final String modelVersion; // e.g. "1.0" for MobileFaceNet

  FacePerson({
    String? id,
    required this.name,
    required this.embeddings,
    this.masterEmbedding,
    DateTime? createdAt,
    this.captureCount = 0,
    this.faceDescription,
    this.storedFaceBytes,
    this.modelVersion = "1.0",
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  // Convert to map for Hive storage
  Map<String, dynamic> toMap() {
    // Create deep copies of lists to ensure proper Hive serialization
    final embeddingsCopy = embeddings
        .map((e) => List<double>.from(e))
        .toList();
    
    return {
      'id': id,
      'name': name,
      'embeddings': embeddingsCopy,
      'masterEmbedding': masterEmbedding != null ? List<double>.from(masterEmbedding!) : null,
      'createdAt': createdAt.toIso8601String(),
      'captureCount': captureCount,
      'faceDescription': faceDescription,
      'storedFaceBytes': storedFaceBytes != null ? List<int>.from(storedFaceBytes!) : null,
      'modelVersion': modelVersion,
    };
  }

  // Create from map
  factory FacePerson.fromMap(Map<String, dynamic> map) {
    // Handle nested list conversion from dynamic
    final embeddingsList = map['embeddings'] as List;
    debugPrint('[FacePerson] Raw embeddings list length: ${embeddingsList.length}');
    
    final embeddings = <List<double>>[];
    for (var embedding in embeddingsList) {
      if (embedding is List) {
        final doubleList = <double>[];
        for (var e in embedding) {
          if (e is double) {
            doubleList.add(e);
          } else if (e is num) {
            doubleList.add(e.toDouble());
          }
        }
        embeddings.add(doubleList);
        debugPrint('[FacePerson] Converted embedding with ${doubleList.length} dimensions');
      }
    }
    debugPrint('[FacePerson] Total embeddings for ${map['name']}: ${embeddings.length}');

    // Handle master embedding conversion
    List<double>? masterEmbedding;
    if (map['masterEmbedding'] != null) {
      final masterList = map['masterEmbedding'] as List;
      masterEmbedding = masterList.map((e) => e is double ? e : (e as num).toDouble()).toList();
    }

    // Handle stored face bytes conversion
    List<int>? storedFaceBytes;
    if (map['storedFaceBytes'] != null) {
      final bytesList = map['storedFaceBytes'] as List;
      storedFaceBytes = bytesList.map((e) => e is int ? e : (e as num).toInt()).toList();
    }

    // Handle model version (default to "1.0" if not present for backward compatibility)
    final modelVersion = map['modelVersion'] as String? ?? "1.0";
    debugPrint('[FacePerson] Loaded ${map['name']} with model version: $modelVersion');

    return FacePerson(
      id: map['id'] as String,
      name: map['name'] as String,
      embeddings: embeddings,
      masterEmbedding: masterEmbedding,
      createdAt: DateTime.parse(map['createdAt'] as String),
      captureCount: map['captureCount'] as int? ?? 0,
      faceDescription: map['faceDescription'] as String?,
      storedFaceBytes: storedFaceBytes,
      modelVersion: modelVersion,
    );
  }

  FacePerson copyWith({
    String? id,
    String? name,
    List<List<double>>? embeddings,
    List<double>? masterEmbedding,
    DateTime? createdAt,
    int? captureCount,
    String? faceDescription,
    List<int>? storedFaceBytes,
    String? modelVersion,
  }) {
    return FacePerson(
      id: id ?? this.id,
      name: name ?? this.name,
      embeddings: embeddings ?? this.embeddings,
      masterEmbedding: masterEmbedding ?? this.masterEmbedding,
      createdAt: createdAt ?? this.createdAt,
      captureCount: captureCount ?? this.captureCount,
      faceDescription: faceDescription ?? this.faceDescription,
      storedFaceBytes: storedFaceBytes ?? this.storedFaceBytes,
      modelVersion: modelVersion ?? this.modelVersion,
    );
  }
}

class PoseData {
  final double yaw; // Positive = turn right, Negative = turn left
  final double pitch; // Positive = look down, Negative = look up
  final double roll; // Rotation (less used)
  final int landmarkCount; // Number of valid landmarks detected

  PoseData({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.landmarkCount,
  });

  @override
  String toString() =>
      'PoseData(yaw: ${yaw.toStringAsFixed(1)}°, pitch: ${pitch.toStringAsFixed(1)}°, roll: ${roll.toStringAsFixed(1)}°)';
}
