import '../models/attempt.dart';
import 'fault_switches.dart';

/// What the create-once transaction found.
enum SaveOutcome {
  /// The document did not exist and was created.
  created,

  /// The document already existed with the same five values. Nothing was
  /// written; the earlier save is reused.
  matchedExisting,

  /// The document already existed with different values. Nothing was
  /// written; the original is preserved.
  collision,
}

enum StoreErrorKind {
  permissionDenied,
  unauthenticated,
  unavailable,
  resourceExhausted,

  /// The request may or may not have been committed.
  outcomeUnknown,
  other,
}

class StoreException implements Exception {
  const StoreException(this.kind, this.code, {this.injected = false});

  final StoreErrorKind kind;

  /// The backend's own code, for example `permission-denied`.
  final String code;

  /// True when the fault lab produced this error on purpose.
  final bool injected;

  @override
  String toString() => 'StoreException(${kind.name}, $code)';
}

/// The cloud score service. The app talks to this interface so the state
/// machine can be unit tested without Firebase.
abstract class AttemptStore {
  /// A new document ID. Generated locally: it reserves nothing on the server.
  String newRoundId(String uid);

  /// Creates `users/{uid}/attempts/{roundId}` if it does not exist yet.
  /// Never overwrites.
  Future<SaveOutcome> createOnce(
    String uid,
    String roundId,
    AttemptPayload payload,
  );

  /// Reads the exact document from the server, never from the cache.
  /// Returns null when the server says it does not exist.
  Future<ServerAttempt?> readFromServer(String uid, String roundId);

  /// The user's most recent attempts, read from the server.
  Future<List<ServerAttempt>> listFromServer(String uid, {int limit = 20});
}

/// Development-only wrapper used by the fault lab.
class FaultInjectingStore implements AttemptStore {
  FaultInjectingStore(this._inner, this._faults);

  final AttemptStore _inner;
  final FaultSwitches _faults;

  @override
  String newRoundId(String uid) => _inner.newRoundId(uid);

  @override
  Future<SaveOutcome> createOnce(
    String uid,
    String roundId,
    AttemptPayload payload,
  ) async {
    switch (_faults.takeSaveFault()) {
      case SaveFault.none:
        return _inner.createOnce(uid, roundId, payload);
      case SaveFault.dropAcknowledgement:
        // T09: the real transaction runs and commits. Only its completion is
        // hidden from the caller, as if the acknowledgement was lost.
        await _inner.createOnce(uid, roundId, payload);
        throw const StoreException(
          StoreErrorKind.outcomeUnknown,
          'acknowledgement-lost',
          injected: true,
        );
      case SaveFault.unavailable:
        // T12: modelled error, nothing is sent.
        throw const StoreException(
          StoreErrorKind.unavailable,
          'unavailable',
          injected: true,
        );
      case SaveFault.resourceExhausted:
        // T12: models quota exhaustion without spending quota.
        throw const StoreException(
          StoreErrorKind.resourceExhausted,
          'resource-exhausted',
          injected: true,
        );
    }
  }

  @override
  Future<ServerAttempt?> readFromServer(String uid, String roundId) =>
      _inner.readFromServer(uid, roundId);

  @override
  Future<List<ServerAttempt>> listFromServer(String uid, {int limit = 20}) =>
      _inner.listFromServer(uid, limit: limit);
}
