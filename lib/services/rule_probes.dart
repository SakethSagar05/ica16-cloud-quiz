import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/attempt.dart';
import '../util/event_log.dart';

/// The result of one deliberately invalid request.
class ProbeResult {
  ProbeResult({
    required this.label,
    required this.passed,
    required this.detail,
  }) : at = DateTime.now();

  final String label;

  /// True when the deployed rules rejected the request as expected.
  final bool passed;
  final String detail;
  final DateTime at;
}

/// Development-only invalid requests for tests T10 and T11. They are sent to
/// the real deployed rules; none of them is expected to succeed.
class RuleProbes {
  RuleProbes([FirebaseFirestore? db]) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _attempts(String uid) =>
      _db.collection('users').doc(uid).collection('attempts');

  Map<String, dynamic> _validData(int correctCount) => <String, dynamic>{
        ...AttemptPayload(correctCount: correctCount).fixedFields,
        AttemptPayload.timestampField: FieldValue.serverTimestamp(),
      };

  Future<ProbeResult> _expectDenied(
    String label,
    Future<void> Function() request,
  ) async {
    try {
      await request().timeout(const Duration(seconds: 15));
      return ProbeResult(
        label: label,
        passed: false,
        detail: 'ALLOWED: the rules did not block this request',
      );
    } on FirebaseException catch (e) {
      return ProbeResult(
        label: label,
        passed: e.code == 'permission-denied',
        detail: 'rejected with ${e.code}',
      );
    } on TimeoutException {
      return ProbeResult(
        label: label,
        passed: false,
        detail: 'no answer from the server within 15 s',
      );
    }
  }

  /// T10: read another user's attempt.
  Future<ProbeResult> readForeign(String otherUid, String roundId) {
    return _expectDenied(
      'T10 read users/..${idSuffix(otherUid)}/attempts/..${idSuffix(roundId)}',
      () => _attempts(otherUid)
          .doc(roundId)
          .get(const GetOptions(source: Source.server)),
    );
  }

  /// T10: create a valid-looking attempt under another user's path.
  Future<ProbeResult> writeForeign(String otherUid) {
    return _expectDenied(
      'T10 write into users/..${idSuffix(otherUid)}/attempts',
      () => _attempts(otherUid).doc().set(_validData(5)),
    );
  }

  /// T11: create an attempt whose score is out of range.
  Future<ProbeResult> createScoreEleven(String uid) {
    return _expectDenied(
      'T11 create with correctCount 11',
      () => _attempts(uid).doc().set(_validData(11)),
    );
  }

  /// T11: create an attempt with a seventh field.
  Future<ProbeResult> createExtraField(String uid) {
    return _expectDenied(
      'T11 create with an extra field',
      () => _attempts(uid).doc().set(<String, dynamic>{
        ..._validData(5),
        'extra': 'not in the schema',
      }),
    );
  }

  /// T11: update an existing attempt, then read it back from the server to
  /// show that the original is unchanged.
  Future<ProbeResult> updateExisting(String uid, String roundId) async {
    final ref = _attempts(uid).doc(roundId);
    final before = await _serverSummary(ref);
    final attempt = await _expectDenied(
      'T11 update existing attempt ..${idSuffix(roundId)}',
      () => ref.update(<String, Object?>{'correctCount': 10}),
    );
    final after = await _serverSummary(ref);
    final unchanged = before != null && before == after;
    return ProbeResult(
      label: attempt.label,
      passed: attempt.passed && unchanged,
      detail: '${attempt.detail}; server copy '
          '${unchanged ? 'unchanged' : 'CHANGED or unreadable'}: '
          '${after ?? 'unreadable'}',
    );
  }

  Future<String?> _serverSummary(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    try {
      final snapshot = await ref
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      final data = snapshot.data();
      if (data == null) {
        return null;
      }
      final stamp = data[AttemptPayload.timestampField];
      final time = stamp is Timestamp ? formatStamp(stamp.toDate()) : '$stamp';
      return 'correctCount=${data['correctCount']} submittedAt=$time';
    } on FirebaseException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
