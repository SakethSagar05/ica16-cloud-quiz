import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/attempt.dart';
import 'attempt_store.dart';

/// Cloud Firestore implementation of the score service.
///
/// Path: `users/{authenticatedUid}/attempts/{roundId}`. One completed round is
/// one immutable document.
class FirestoreAttemptStore implements AttemptStore {
  FirestoreAttemptStore([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _attempts(String uid) =>
      _db.collection('users').doc(uid).collection('attempts');

  @override
  String newRoundId(String uid) => _attempts(uid).doc().id;

  @override
  Future<SaveOutcome> createOnce(
    String uid,
    String roundId,
    AttemptPayload payload,
  ) async {
    final ref = _attempts(uid).doc(roundId);
    // Built once, outside the transaction, so every run of the callback
    // writes the same six fields. The timestamp is a sentinel that the
    // server replaces with its own commit time.
    final data = <String, dynamic>{
      ...payload.fixedFields,
      AttemptPayload.timestampField: FieldValue.serverTimestamp(),
    };
    try {
      return await _db.runTransaction<SaveOutcome>((transaction) async {
        // Firestore may run this callback more than once, so it only reads,
        // compares and writes this one document. No UI updates, no ID
        // generation, no other network calls and no counters live here.
        final snapshot = await transaction.get(ref);
        if (!snapshot.exists) {
          transaction.set(ref, data);
          return SaveOutcome.created;
        }
        final existing = snapshot.data();
        if (existing != null && payload.matchesFixed(existing)) {
          return SaveOutcome.matchedExisting;
        }
        return SaveOutcome.collision;
      });
    } on FirebaseException catch (e) {
      throw _toStoreException(e);
    }
  }

  @override
  Future<ServerAttempt?> readFromServer(String uid, String roundId) async {
    try {
      final snapshot = await _attempts(uid)
          .doc(roundId)
          .get(const GetOptions(source: Source.server));
      if (!snapshot.exists) {
        return null;
      }
      return _fromSnapshot(snapshot);
    } on FirebaseException catch (e) {
      throw _toStoreException(e);
    }
  }

  @override
  Future<List<ServerAttempt>> listFromServer(
    String uid, {
    int limit = 20,
  }) async {
    try {
      final query = await _attempts(uid)
          .orderBy(AttemptPayload.timestampField, descending: true)
          .limit(limit)
          .get(const GetOptions(source: Source.server));
      return query.docs.map(_fromSnapshot).toList();
    } on FirebaseException catch (e) {
      throw _toStoreException(e);
    }
  }

  ServerAttempt _fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data() ?? const <String, dynamic>{};
    final stamp = data[AttemptPayload.timestampField];
    return ServerAttempt(
      path: snapshot.reference.path,
      roundId: snapshot.id,
      data: data,
      submittedAt: stamp is Timestamp ? stamp.toDate() : null,
      fromCache: snapshot.metadata.isFromCache,
      hasPendingWrites: snapshot.metadata.hasPendingWrites,
    );
  }

  StoreException _toStoreException(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return StoreException(StoreErrorKind.permissionDenied, e.code);
      case 'unauthenticated':
        return StoreException(StoreErrorKind.unauthenticated, e.code);
      case 'unavailable':
        return StoreException(StoreErrorKind.unavailable, e.code);
      case 'resource-exhausted':
        return StoreException(StoreErrorKind.resourceExhausted, e.code);
      case 'deadline-exceeded':
      case 'cancelled':
        // The request may have reached the server before it was cut off.
        return StoreException(StoreErrorKind.outcomeUnknown, e.code);
      default:
        return StoreException(StoreErrorKind.other, e.code);
    }
  }
}
