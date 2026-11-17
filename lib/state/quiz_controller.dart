import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/attempt.dart';
import '../models/question.dart';
import '../services/attempt_store.dart';
import '../services/auth_gateway.dart';
import '../services/trivia_api.dart';
import '../util/event_log.dart';

/// Every state the app can be in. The main path is
/// signedOut -> home -> loading -> playing -> readyToSubmit -> submitting ->
/// verifying -> cloudVerified. The other values are the explicit branches.
enum QuizPhase {
  signedOut,
  authError,
  home,
  loading,
  requestError,
  playing,
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  permissionDenied,
  saveFailed,
  collision,
  verificationUnavailable,
}

/// Tracks whether one save operation has really finished, even after the UI
/// stopped waiting for it. A Dart timeout does not cancel the operation.
class _SaveTicket {
  bool settled = false;
}

/// An attempt that was cloud verified during this app session (memory only).
class VerifiedRef {
  const VerifiedRef(this.uid, this.roundId);

  final String uid;
  final String roundId;
}

class QuizController extends ChangeNotifier {
  QuizController({
    required AuthGateway auth,
    required TriviaApi api,
    required AttemptStore store,
    EventLog? log,
    DateTime Function()? clock,
    this.saveTimeout = QuizConfig.saveUiTimeout,
    this.verifyTimeout = QuizConfig.verifyTimeout,
    this.minRequestGap = QuizConfig.minRequestGap,
    this.enableTicker = true,
  })  : _auth = auth,
        _api = api,
        _store = store,
        _log = log,
        _clock = clock ?? DateTime.now {
    _authSubscription = _auth.userChanges.listen(_onUserChanged);
  }

  final AuthGateway _auth;
  final TriviaApi _api;
  final AttemptStore _store;
  final EventLog? _log;
  final DateTime Function() _clock;

  final Duration saveTimeout;
  final Duration verifyTimeout;
  final Duration minRequestGap;
  final bool enableTicker;

  static const Set<QuizPhase> _unresolvedPhases = <QuizPhase>{
    QuizPhase.submitting,
    QuizPhase.verifying,
    QuizPhase.saveUnknown,
    QuizPhase.verificationUnavailable,
  };

  static const Set<QuizPhase> _startablePhases = <QuizPhase>{
    QuizPhase.home,
    QuizPhase.requestError,
    QuizPhase.readyToSubmit,
    QuizPhase.cloudVerified,
    QuizPhase.permissionDenied,
    QuizPhase.saveFailed,
    QuizPhase.collision,
  };

  static const Set<QuizPhase> _submittablePhases = <QuizPhase>{
    QuizPhase.readyToSubmit,
    QuizPhase.permissionDenied,
    QuizPhase.saveFailed,
  };

  late final StreamSubscription<AuthUser?> _authSubscription;
  Timer? _cooldownTimer;
  bool _disposed = false;

  // ---- identity -----------------------------------------------------------
  String? _uid;
  String? _email;
  bool _signingIn = false;

  // ---- phase --------------------------------------------------------------
  QuizPhase _phase = QuizPhase.signedOut;
  String? _message;
  bool _injected = false;

  /// Bumped whenever a new operation starts or the user changes. A response
  /// is applied only if this value, the UID and the round ID are all still
  /// the ones that started it.
  int _generation = 0;

  // ---- round --------------------------------------------------------------
  String? _roundId;
  List<Question> _questions = const <Question>[];
  List<int?> _selections = <int?>[];
  int _index = 0;
  int _score = 0;
  DateTime? _lastRequestAt;

  // ---- submission ---------------------------------------------------------
  AttemptPayload? _payload;
  _SaveTicket? _ticket;
  SaveOutcome? _outcome;
  ServerAttempt? _verified;
  bool _recovered = false;
  StoreErrorKind? _failureKind;
  String? _failureCode;

  // ---- session memory (never written to disk) -----------------------------
  final List<VerifiedRef> _sessionVerified = <VerifiedRef>[];
  bool _showFullIds = false;

  // ---- read-only view for the widgets -------------------------------------
  QuizPhase get phase => _phase;
  String? get message => _message;
  bool get injected => _injected;
  String? get uid => _uid;
  String? get email => _email;
  bool get signingIn => _signingIn;
  String? get roundId => _roundId;
  List<Question> get questions => _questions;
  List<int?> get selections => List<int?>.unmodifiable(_selections);
  int get index => _index;
  int get score => _score;
  Question get currentQuestion => _questions[_index];
  int? get currentSelection => _selections[_index];
  bool get currentAnswered => _selections[_index] != null;
  bool get isLastQuestion => _index == _questions.length - 1;
  AttemptPayload? get payload => _payload;
  SaveOutcome? get outcome => _outcome;
  ServerAttempt? get verified => _verified;
  bool get recovered => _recovered;
  StoreErrorKind? get failureKind => _failureKind;
  String? get failureCode => _failureCode;
  bool get showFullIds => _showFullIds;

  /// True while a submission is pending or its result is not known yet.
  /// Replay and sign-out stay disabled until a server read resolves it.
  bool get isUnresolved => _unresolvedPhases.contains(_phase);

  /// True when no save operation is still running in the background.
  bool get saveSettled => _ticket?.settled ?? true;

  bool get canSignOut => _uid != null && !isUnresolved && saveSettled;

  bool get canGoHome => _uid != null && !isUnresolved && saveSettled;

  bool get canSubmit =>
      _payload != null && _submittablePhases.contains(_phase) && saveSettled;

  bool get canStartRound =>
      _uid != null &&
      _startablePhases.contains(_phase) &&
      saveSettled &&
      cooldownRemaining == Duration.zero;

  /// Time left before the next OpenTDB request is allowed.
  Duration get cooldownRemaining {
    final last = _lastRequestAt;
    if (last == null) {
      return Duration.zero;
    }
    final left = minRequestGap - _clock().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  int get cooldownSeconds => (cooldownRemaining.inMilliseconds / 1000).ceil();

  VerifiedRef? get lastVerifiedMine {
    for (final ref in _sessionVerified.reversed) {
      if (ref.uid == _uid) {
        return ref;
      }
    }
    return null;
  }

  VerifiedRef? get lastVerifiedOtherUser {
    for (final ref in _sessionVerified.reversed) {
      if (ref.uid != _uid) {
        return ref;
      }
    }
    return null;
  }

  /// IDs are shown as a six-character suffix unless the user asks for more,
  /// so screenshots are redacted by default.
  String shownId(String? id) {
    if (id == null || id.isEmpty) {
      return '-';
    }
    return _showFullIds ? id : '..${idSuffix(id)}';
  }

  String shownPath(String path) {
    final parts = path.split('/');
    if (_showFullIds || parts.length != 4) {
      return path;
    }
    return '${parts[0]}/..${idSuffix(parts[1])}/${parts[2]}/..${idSuffix(parts[3])}';
  }

  void toggleFullIds() {
    _showFullIds = !_showFullIds;
    _notify();
  }

  // ---- authentication -----------------------------------------------------

  Future<void> signIn(String email, String password) async {
    if (_signingIn || _uid != null) {
      return;
    }
    _signingIn = true;
    if (_phase == QuizPhase.authError) {
      _setPhase(QuizPhase.signedOut, note: 'retrying sign-in');
    }
    _notify();
    try {
      // Success arrives through userChanges, not through this call.
      await _auth.signIn(email, password);
    } on AuthFailure catch (e) {
      if (_uid == null) {
        _setPhase(
          QuizPhase.authError,
          message: e.message,
          note: 'code=${e.code}',
        );
      }
    } finally {
      _signingIn = false;
      _notify();
    }
  }

  Future<void> signOut() async {
    if (!canSignOut) {
      _trace('sign-out ignored: a submission is unresolved');
      return;
    }
    await _auth.signOut();
  }

  void _onUserChanged(AuthUser? user) {
    final newUid = user?.uid;
    if (newUid == _uid) {
      _email = user?.email;
      return;
    }
    final hadUnresolved = isUnresolved || !saveSettled;
    // Any response still in flight now belongs to the previous user.
    _generation++;
    _uid = newUid;
    _email = user?.email;
    _clearRound();
    if (newUid == null) {
      if (_phase != QuizPhase.authError) {
        _setPhase(QuizPhase.signedOut, note: 'no user');
      }
    } else {
      _setPhase(QuizPhase.home, note: 'authenticated');
    }
    if (hadUnresolved) {
      _trace('user changed during a submission: its response will be ignored');
    }
    _notify();
  }

  // ---- loading a round ----------------------------------------------------

  /// Starts a new round (from home, after an error, or as a replay).
  Future<void> startRound() async {
    final uid = _uid;
    if (uid == null || !canStartRound) {
      _trace('startRound ignored in ${_phase.name}');
      return;
    }
    // A retry of a failed load keeps its round ID. A new round or a replay
    // gets a new one. The ID is generated locally and reserves nothing.
    final previous = _roundId;
    final roundId = (_phase == QuizPhase.requestError && previous != null)
        ? previous
        : _store.newRoundId(uid);
    _clearRound();
    _roundId = roundId;
    final generation = ++_generation;
    _lastRequestAt = _clock();
    _startCooldownTicker();
    _setPhase(
      QuizPhase.loading,
      note: 'GET opentdb amount=10 category=9 difficulty=easy type=multiple',
    );
    _notify();

    try {
      final questions = await _api.fetchRound();
      if (!_isCurrent(generation, uid, roundId)) {
        _trace('stale question response ignored');
        return;
      }
      _questions = questions;
      _selections = List<int?>.filled(questions.length, null);
      _index = 0;
      _score = 0;
      _setPhase(
        QuizPhase.playing,
        note: 'validated ${questions.length} questions',
      );
    } on TriviaException catch (e) {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _setPhase(
        QuizPhase.requestError,
        message: e.message,
        injected: e.injected,
        note: 'kind=${e.kind.name}',
      );
    } catch (e) {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _setPhase(
        QuizPhase.requestError,
        message: 'The round could not be loaded (${e.runtimeType}).',
        note: 'unexpected',
      );
    }
    _notify();
  }

  void goHome() {
    if (!canGoHome) {
      return;
    }
    _generation++;
    _clearRound();
    _setPhase(QuizPhase.home, note: 'back to home');
    _notify();
  }

  // ---- playing ------------------------------------------------------------

  /// Records the answer for the current question. Only the first tap counts.
  void answer(int choiceIndex) {
    if (_phase != QuizPhase.playing) {
      return;
    }
    if (currentAnswered) {
      _trace('answer ignored: question ${_index + 1} is already answered');
      return;
    }
    final question = currentQuestion;
    if (choiceIndex < 0 || choiceIndex >= question.choices.length) {
      return;
    }
    _selections[_index] = choiceIndex;
    final correct = choiceIndex == question.correctIndex;
    if (correct) {
      _score++;
    }
    _trace(
      'answered question ${_index + 1}: '
      '${correct ? 'correct' : 'incorrect'}, score=$_score',
    );
    _notify();
  }

  /// Moves on. An answer is required first.
  void next() {
    if (_phase != QuizPhase.playing || !currentAnswered) {
      return;
    }
    if (!isLastQuestion) {
      _index++;
    } else {
      // The round is complete: freeze the payload. Retries reuse this exact
      // object and this round ID.
      _payload = AttemptPayload(correctCount: _score);
      _setPhase(
        QuizPhase.readyToSubmit,
        note: 'payload frozen correctCount=$_score',
      );
    }
    _notify();
  }

  // ---- saving -------------------------------------------------------------

  /// Runs the create-once transaction, then verifies it with a server read.
  Future<void> submit() async {
    final uid = _uid;
    final roundId = _roundId;
    final payload = _payload;
    if (uid == null || roundId == null || payload == null || !canSubmit) {
      _trace('submit ignored in ${_phase.name}');
      return;
    }
    final generation = ++_generation;
    final ticket = _SaveTicket();
    _ticket = ticket;
    _failureKind = null;
    _failureCode = null;
    _setPhase(QuizPhase.submitting, note: 'create-once transaction started');
    _notify();

    final operation =
        _store.createOnce(uid, roundId, payload).whenComplete(() {
      ticket.settled = true;
      if (identical(_ticket, ticket) && _phase == QuizPhase.saveUnknown) {
        _trace('the earlier save operation has now finished');
        _notify();
      }
    });

    SaveOutcome outcome;
    try {
      outcome = await operation.timeout(saveTimeout);
    } on TimeoutException {
      if (!_isCurrent(generation, uid, roundId)) {
        _trace('stale save timeout ignored');
        return;
      }
      // Not a failure: the write may have been committed.
      _setPhase(
        QuizPhase.saveUnknown,
        message: 'No answer after ${saveTimeout.inSeconds} seconds. The save '
            'may or may not have reached the cloud. Check the cloud to find '
            'out; nothing is assumed.',
        note: 'ui timeout',
      );
      _notify();
      return;
    } on StoreException catch (e) {
      if (!_isCurrent(generation, uid, roundId)) {
        _trace('stale save error ignored');
        return;
      }
      _applyStoreError(e);
      _notify();
      return;
    } catch (e) {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _failureKind = StoreErrorKind.other;
      _failureCode = '${e.runtimeType}';
      _setPhase(
        QuizPhase.saveFailed,
        message: 'The save did not complete (${e.runtimeType}). Nothing was '
            'confirmed. You can retry with the same round ID.',
        note: 'unexpected',
      );
      _notify();
      return;
    }

    if (!_isCurrent(generation, uid, roundId)) {
      _trace('stale save response ignored');
      return;
    }
    if (outcome == SaveOutcome.collision) {
      _setPhase(
        QuizPhase.collision,
        message: 'A different attempt already exists under this round ID. '
            'It was not overwritten, and this score was not saved.',
        note: 'existing document has different values',
      );
      _notify();
      return;
    }
    _outcome = outcome;
    _trace('transaction finished: ${outcome.name}');
    await _verify(
      generation: generation,
      uid: uid,
      roundId: roundId,
      payload: payload,
      recovering: false,
    );
  }

  /// From saveUnknown: ask the server what happened. No write is sent.
  Future<void> resolveUnknown() async {
    final uid = _uid;
    final roundId = _roundId;
    final payload = _payload;
    if (_phase != QuizPhase.saveUnknown ||
        uid == null ||
        roundId == null ||
        payload == null) {
      return;
    }
    await _verify(
      generation: ++_generation,
      uid: uid,
      roundId: roundId,
      payload: payload,
      recovering: true,
    );
  }

  /// From verificationUnavailable: repeat the server read only.
  Future<void> retryVerification() async {
    final uid = _uid;
    final roundId = _roundId;
    final payload = _payload;
    if (_phase != QuizPhase.verificationUnavailable ||
        uid == null ||
        roundId == null ||
        payload == null) {
      return;
    }
    await _verify(
      generation: ++_generation,
      uid: uid,
      roundId: roundId,
      payload: payload,
      recovering: false,
    );
  }

  Future<void> _verify({
    required int generation,
    required String uid,
    required String roundId,
    required AttemptPayload payload,
    required bool recovering,
  }) async {
    final wasInjected = _injected;
    _setPhase(
      QuizPhase.verifying,
      note: recovering ? 'recovery read, server only' : 'server-only read',
    );
    _notify();

    ServerAttempt? found;
    try {
      found = await _store.readFromServer(uid, roundId).timeout(verifyTimeout);
    } on TimeoutException {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _readFailed(
        recovering,
        'the server did not answer within ${verifyTimeout.inSeconds} seconds',
        wasInjected,
      );
      return;
    } on StoreException catch (e) {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _readFailed(recovering, 'the server read failed (${e.code})', wasInjected);
      return;
    } catch (_) {
      if (!_isCurrent(generation, uid, roundId)) {
        return;
      }
      _readFailed(recovering, 'the server read failed', wasInjected);
      return;
    }

    if (!_isCurrent(generation, uid, roundId)) {
      _trace('stale verification response ignored');
      return;
    }

    if (found == null) {
      if (!recovering) {
        _setPhase(
          QuizPhase.verificationUnavailable,
          message: 'The save transaction finished, but the server read did '
              'not return the document. This is not a failed save. Retry '
              'the verification.',
          note: 'document not returned',
        );
      } else if (saveSettled) {
        _setPhase(
          QuizPhase.readyToSubmit,
          message: 'The server has no document for this round and the earlier '
              'submission has finished, so nothing was saved. Submit again: '
              'the same round ID is reused.',
          note: 'reconciled: not saved, safe to retry with the same ID',
        );
      } else {
        _setPhase(
          QuizPhase.saveUnknown,
          message: 'The server has no document for this round yet, and the '
              'earlier submission is still in flight. Check again in a few '
              'seconds before retrying.',
          injected: wasInjected,
          note: 'earlier operation not settled',
        );
      }
      _notify();
      return;
    }

    final problem = found.problemAgainst(payload);
    if (problem == null) {
      _verified = found;
      _recovered = recovering;
      _sessionVerified.add(VerifiedRef(uid, roundId));
      _setPhase(
        QuizPhase.cloudVerified,
        note: '${recovering ? 'recovered by server read' : 'verified'} '
            'correctCount=${found.correctCount} '
            'submittedAt=${formatStamp(found.submittedAt)} '
            'fromCache=${found.fromCache} '
            'pendingWrites=${found.hasPendingWrites}',
      );
    } else if (!payload.matchesFixed(found.data)) {
      _setPhase(
        QuizPhase.collision,
        message: 'The server holds a different attempt under this round ID. '
            'It was not overwritten.',
        note: 'server values differ',
      );
    } else if (recovering) {
      _setPhase(
        QuizPhase.saveUnknown,
        message: 'The document was found, but $problem. Check again.',
        injected: wasInjected,
        note: 'not verifiable yet',
      );
    } else {
      _setPhase(
        QuizPhase.verificationUnavailable,
        message: 'The document was found, but $problem. Retry the '
            'verification.',
        note: 'not verifiable yet',
      );
    }
    _notify();
  }

  void _readFailed(bool recovering, String why, bool wasInjected) {
    if (recovering) {
      _setPhase(
        QuizPhase.saveUnknown,
        message: 'Still unknown: $why. Reconnect, then check the cloud again.',
        injected: wasInjected,
        note: 'recovery read failed',
      );
    } else {
      _setPhase(
        QuizPhase.verificationUnavailable,
        message: 'The save transaction finished, but $why. This is not a '
            'failed save. Retry the verification when you are online.',
        note: 'verification read failed',
      );
    }
    _notify();
  }

  void _applyStoreError(StoreException e) {
    _failureKind = e.kind;
    _failureCode = e.code;
    switch (e.kind) {
      case StoreErrorKind.outcomeUnknown:
        _setPhase(
          QuizPhase.saveUnknown,
          message: e.injected
              ? 'The acknowledgement for this save was dropped on purpose. '
                  'The app does not know whether the cloud has the attempt. '
                  'Check the cloud to find out.'
              : 'The connection was cut before the cloud answered '
                  '(${e.code}). The save may or may not have been committed. '
                  'Check the cloud to find out.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
      case StoreErrorKind.permissionDenied:
        _setPhase(
          QuizPhase.permissionDenied,
          message: 'The security rules rejected this save '
              '(permission-denied). Nothing was written.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
      case StoreErrorKind.unauthenticated:
        _setPhase(
          QuizPhase.saveFailed,
          message: 'The cloud no longer accepts this sign-in '
              '(unauthenticated). Nothing was written. Sign in again.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
      case StoreErrorKind.unavailable:
        _setPhase(
          QuizPhase.saveFailed,
          message: 'The cloud could not be reached (unavailable). Nothing '
              'was confirmed as saved. Retry when you are online; the same '
              'round ID is reused.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
      case StoreErrorKind.resourceExhausted:
        _setPhase(
          QuizPhase.saveFailed,
          message: 'The project quota is used up (resource-exhausted). '
              'Nothing was saved. Retry later; the app will not retry on '
              'its own.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
      case StoreErrorKind.other:
        _setPhase(
          QuizPhase.saveFailed,
          message: 'The save failed (${e.code}). Nothing was confirmed. You '
              'can retry with the same round ID.',
          injected: e.injected,
          note: 'code=${e.code}',
        );
    }
  }

  // ---- helpers ------------------------------------------------------------

  bool _isCurrent(int generation, String uid, String roundId) =>
      generation == _generation && uid == _uid && roundId == _roundId;

  void _clearRound() {
    _roundId = null;
    _questions = const <Question>[];
    _selections = <int?>[];
    _index = 0;
    _score = 0;
    _payload = null;
    _ticket = null;
    _outcome = null;
    _verified = null;
    _recovered = false;
    _failureKind = null;
    _failureCode = null;
  }

  void _setPhase(
    QuizPhase next, {
    String? message,
    bool injected = false,
    String note = '',
  }) {
    final previous = _phase;
    _phase = next;
    _message = message;
    _injected = injected;
    _trace(
      '${previous.name} -> ${next.name}'
      '${injected ? ' [INJECTED]' : ''}'
      '${note.isEmpty ? '' : ' ($note)'}',
    );
  }

  void _trace(String event) {
    _log?.add('uid=..${idSuffix(_uid)} round=..${idSuffix(_roundId)} $event');
  }

  void _startCooldownTicker() {
    if (!enableTicker) {
      return;
    }
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (cooldownRemaining == Duration.zero) {
        timer.cancel();
      }
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cooldownTimer?.cancel();
    _authSubscription.cancel();
    super.dispose();
  }
}
