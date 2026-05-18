class SavedResponse {
  final String id;
  final String title;
  final String fullText;
  final DateTime timestamp;

  SavedResponse({
    required this.id,
    required this.title,
    required this.fullText,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'fullText': fullText,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory SavedResponse.fromMap(Map<dynamic, dynamic> map) {
    return SavedResponse(
      id: map['id'] as String,
      title: map['title'] as String,
      fullText: map['fullText'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}
