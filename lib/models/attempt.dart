import '../config.dart';

/// The frozen result of one completed round. These five values plus the
/// server timestamp are the whole cloud document; the document ID is the
/// round ID, so no ID field is stored.
class AttemptPayload {
  const AttemptPayload({required this.correctCount});

  final int correctCount;

  static const List<String> fixedFieldNames = <String>[
    'schemaVersion',
    'variant',
    'categoryId',
    'questionCount',
    'correctCount',
  ];

  static const String timestampField = 'submittedAt';

  Map<String, Object> get fixedFields => <String, Object>{
        'schemaVersion': QuizConfig.schemaVersion,
        'variant': QuizConfig.variant,
        'categoryId': QuizConfig.categoryId,
        'questionCount': QuizConfig.questionCount,
        'correctCount': correctCount,
      };

  /// True when [data] holds the same five non-timestamp values.
  bool matchesFixed(Map<String, dynamic> data) {
    final mine = fixedFields;
    for (final name in fixedFieldNames) {
      if (data[name] != mine[name]) {
        return false;
      }
    }
    return true;
  }
}

/// One attempt document as a server-only read returned it.
class ServerAttempt {
  const ServerAttempt({
    required this.path,
    required this.roundId,
    required this.data,
    required this.submittedAt,
    required this.fromCache,
    required this.hasPendingWrites,
  });

  /// `users/{uid}/attempts/{roundId}`
  final String path;
  final String roundId;
  final Map<String, dynamic> data;

  /// The resolved server timestamp, or null if it is not a timestamp yet.
  final DateTime? submittedAt;

  /// Snapshot metadata. A verified attempt needs both to be false.
  final bool fromCache;
  final bool hasPendingWrites;

  int? get correctCount {
    final value = data['correctCount'];
    return value is int ? value : null;
  }

  /// Null when this snapshot proves that the cloud holds [expected].
  /// Otherwise the reason it does not.
  String? problemAgainst(AttemptPayload expected) {
    if (fromCache) {
      return 'the snapshot came from the local cache, not the server';
    }
    if (hasPendingWrites) {
      return 'the snapshot still has pending local writes';
    }
    final keys = data.keys.toSet();
    final wanted = <String>{
      ...AttemptPayload.fixedFieldNames,
      AttemptPayload.timestampField,
    };
    if (keys.length != wanted.length || !keys.containsAll(wanted)) {
      return 'the document does not have exactly the six schema fields';
    }
    if (!expected.matchesFixed(data)) {
      return 'the stored values differ from this round';
    }
    if (submittedAt == null) {
      return 'the server timestamp is not resolved';
    }
    return null;
  }
}
