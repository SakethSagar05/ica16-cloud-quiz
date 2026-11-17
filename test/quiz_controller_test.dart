import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ica16_cloud_quiz/models/attempt.dart';
import 'package:ica16_cloud_quiz/models/question.dart';
import 'package:ica16_cloud_quiz/services/attempt_store.dart';
import 'package:ica16_cloud_quiz/services/auth_gateway.dart';
import 'package:ica16_cloud_quiz/services/trivia_api.dart';
import 'package:ica16_cloud_quiz/state/quiz_controller.dart';

const AuthUser userA = AuthUser(uid: 'userA', email: 'a@example.com');

class FakeAuth implements AuthGateway {
  // Broadcast, so a rebuilt controller can listen again. A new listener gets
  // no replay: tests emit the user after building a controller.
  final StreamController<AuthUser?> _changes =
      StreamController<AuthUser?>.broadcast(sync: true);
  AuthFailure? failNextSignIn;

  @override
  Stream<AuthUser?> get userChanges => _changes.stream;

  void emit(AuthUser? user) => _changes.add(user);

  @override
  Future<void> signIn(String email, String password) async {
    final failure = failNextSignIn;
    if (failure != null) {
      failNextSignIn = null;
      throw failure;
    }
    emit(userA);
  }

  @override
  Future<void> signOut() async => emit(null);
}

class FakeApi implements TriviaApi {
  TriviaException? failNext;
  int calls = 0;

  @override
  Future<List<Question>> fetchRound() async {
    calls++;
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    return <Question>[
      for (var i = 1; i <= 10; i++)
        Question(
          text: 'Q$i',
          correctAnswer: 'R$i',
          choices: <String>['R$i', 'W${i}a', 'W${i}b', 'W${i}c'],
        ),
    ];
  }
}

class FakeStore implements AttemptStore {
  final Map<String, Map<String, dynamic>> docs =
      <String, Map<String, dynamic>>{};
  int createCalls = 0;
  int idCounter = 0;
  StoreException? failNextCreate;
  StoreException? failNextRead;
  bool dropNextAck = false;
  Completer<void>? holdCreate;

  String path(String uid, String roundId) => 'users/$uid/attempts/$roundId';

  int docCount(String uid) =>
      docs.keys.where((key) => key.startsWith('users/$uid/')).length;

  @override
  String newRoundId(String uid) => 'round${++idCounter}';

  @override
  Future<SaveOutcome> createOnce(
    String uid,
    String roundId,
    AttemptPayload payload,
  ) async {
    createCalls++;
    final hold = holdCreate;
    if (hold != null) {
      holdCreate = null;
      await hold.future;
    }
    final failure = failNextCreate;
    if (failure != null) {
      failNextCreate = null;
      throw failure;
    }
    final key = path(uid, roundId);
    final existing = docs[key];
    final SaveOutcome outcome;
    if (existing == null) {
      docs[key] = <String, dynamic>{
        ...payload.fixedFields,
        'submittedAt': DateTime.utc(2026, 11, 16, 20),
      };
      outcome = SaveOutcome.created;
    } else if (payload.matchesFixed(existing)) {
      outcome = SaveOutcome.matchedExisting;
    } else {
      outcome = SaveOutcome.collision;
    }
    if (dropNextAck) {
      dropNextAck = false;
      throw const StoreException(
        StoreErrorKind.outcomeUnknown,
        'acknowledgement-lost',
        injected: true,
      );
    }
    return outcome;
  }

  @override
  Future<ServerAttempt?> readFromServer(String uid, String roundId) async {
    final failure = failNextRead;
    if (failure != null) {
      failNextRead = null;
      throw failure;
    }
    final data = docs[path(uid, roundId)];
    if (data == null) {
      return null;
    }
    return ServerAttempt(
      path: path(uid, roundId),
      roundId: roundId,
      data: data,
      submittedAt: data['submittedAt'] as DateTime?,
      fromCache: false,
      hasPendingWrites: false,
    );
  }

  @override
  Future<List<ServerAttempt>> listFromServer(
    String uid, {
    int limit = 20,
  }) async =>
      <ServerAttempt>[];
}

void main() {
  late FakeAuth auth;
  late FakeApi api;
  late FakeStore store;
  late QuizController controller;

  QuizController build({
    Duration saveTimeout = const Duration(seconds: 5),
    Duration gap = Duration.zero,
    DateTime Function()? clock,
  }) {
    return QuizController(
      auth: auth,
      api: api,
      store: store,
      clock: clock,
      saveTimeout: saveTimeout,
      verifyTimeout: const Duration(seconds: 5),
      minRequestGap: gap,
      enableTicker: false,
    );
  }

  /// Plays a whole round with [correct] right answers.
  Future<void> playRound(QuizController c, {int correct = 7}) async {
    await c.startRound();
    expect(c.phase, QuizPhase.playing);
    for (var i = 0; i < 10; i++) {
      final right = c.currentQuestion.correctIndex;
      c.answer(i < correct ? right : (right + 1) % 4);
      c.next();
    }
    expect(c.phase, QuizPhase.readyToSubmit);
  }

  setUp(() {
    auth = FakeAuth();
    api = FakeApi();
    store = FakeStore();
    controller = build();
    auth.emit(userA);
  });

  tearDown(() => controller.dispose());

  test('sign-in error is visible and a later sign-in reaches home', () async {
    controller.dispose();
    auth = FakeAuth();
    controller = build();
    auth.emit(null);
    expect(controller.phase, QuizPhase.signedOut);

    auth.failNextSignIn = const AuthFailure(
      'invalid-credential',
      'Email or password is incorrect.',
    );
    await controller.signIn('a@example.com', 'wrong');
    expect(controller.phase, QuizPhase.authError);
    expect(controller.message, 'Email or password is incorrect.');
    expect(controller.uid, isNull);

    await controller.signIn('a@example.com', 'right');
    expect(controller.phase, QuizPhase.home);
    expect(controller.uid, 'userA');
  });

  test('a request error blocks play and offers a retry', () async {
    api.failNext = const TriviaException(TriviaErrorKind.apiCode, 'code 1');
    await controller.startRound();
    expect(controller.phase, QuizPhase.requestError);
    expect(controller.questions, isEmpty);
    final failedRound = controller.roundId;

    await controller.startRound();
    expect(controller.phase, QuizPhase.playing);
    expect(controller.roundId, failedRound);
    expect(api.calls, 2);
  });

  test('requests are at least five seconds apart', () async {
    controller.dispose();
    var now = DateTime.utc(2026, 11, 16, 20);
    controller = build(
      gap: const Duration(seconds: 5),
      clock: () => now,
    );
    auth.emit(userA);
    api.failNext = const TriviaException(TriviaErrorKind.schema, 'nine');
    await controller.startRound();
    expect(controller.phase, QuizPhase.requestError);

    now = now.add(const Duration(seconds: 3));
    expect(controller.canStartRound, isFalse);
    expect(controller.cooldownSeconds, 2);
    await controller.startRound();
    expect(api.calls, 1);

    now = now.add(const Duration(seconds: 2));
    expect(controller.canStartRound, isTrue);
    await controller.startRound();
    expect(api.calls, 2);
    expect(controller.phase, QuizPhase.playing);
  });

  test('one answer per question: a second tap changes nothing', () async {
    await controller.startRound();
    final right = controller.currentQuestion.correctIndex;

    controller.next();
    expect(controller.index, 0, reason: 'an answer is required first');

    controller.answer(right);
    controller.answer((right + 1) % 4);
    controller.answer(right);
    expect(controller.score, 1);
    expect(controller.currentSelection, right);

    controller.next();
    controller.answer((controller.currentQuestion.correctIndex + 1) % 4);
    expect(controller.score, 1);
  });

  test('finishing freezes the payload; replay resets everything', () async {
    await playRound(controller, correct: 7);
    expect(controller.score, 7);
    expect(controller.payload?.correctCount, 7);
    expect(controller.selections.whereType<int>(), hasLength(10));
    final firstRound = controller.roundId;

    await controller.startRound();
    expect(controller.phase, QuizPhase.playing);
    expect(controller.roundId, isNot(firstRound));
    expect(controller.score, 0);
    expect(controller.index, 0);
    expect(controller.selections.whereType<int>(), isEmpty);
    expect(controller.payload, isNull);
  });

  test('submit plus a double tap writes one document and verifies it',
      () async {
    await playRound(controller, correct: 6);
    final first = controller.submit();
    final second = controller.submit();
    await Future.wait(<Future<void>>[first, second]);

    expect(controller.phase, QuizPhase.cloudVerified);
    expect(store.createCalls, 1);
    expect(store.docCount('userA'), 1);
    expect(controller.verified?.correctCount, 6);
    expect(controller.verified?.submittedAt, isNotNull);
    expect(controller.recovered, isFalse);
  });

  test('lost acknowledgement: unknown, then recovered by a server read',
      () async {
    await playRound(controller, correct: 8);
    final roundId = controller.roundId;
    store.dropNextAck = true;
    await controller.submit();

    expect(controller.phase, QuizPhase.saveUnknown);
    expect(controller.injected, isTrue);
    expect(controller.isUnresolved, isTrue);
    expect(controller.canStartRound, isFalse);
    expect(controller.canSignOut, isFalse);

    await controller.resolveUnknown();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(controller.recovered, isTrue);
    expect(controller.roundId, roundId);
    expect(store.createCalls, 1, reason: 'recovery never writes again');
    expect(store.docCount('userA'), 1);
  });

  test('a UI timeout is unknown, not failed, and does not cancel the save',
      () async {
    controller.dispose();
    controller = build(saveTimeout: const Duration(milliseconds: 40));
    auth.emit(userA);
    await playRound(controller, correct: 5);
    final hold = Completer<void>();
    store.holdCreate = hold;

    await controller.submit();
    expect(controller.phase, QuizPhase.saveUnknown);
    expect(controller.saveSettled, isFalse);
    expect(store.docCount('userA'), 0);

    // The server has nothing yet and the operation is still running:
    // the app must not offer a retry.
    await controller.resolveUnknown();
    expect(controller.phase, QuizPhase.saveUnknown);

    // The original operation commits after the UI stopped waiting.
    hold.complete();
    await pumpEventQueue();
    expect(controller.saveSettled, isTrue);

    await controller.resolveUnknown();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(store.createCalls, 1);
    expect(store.docCount('userA'), 1);
  });

  test('unknown, server has nothing, operation settled: retry keeps the ID',
      () async {
    await playRound(controller, correct: 4);
    final roundId = controller.roundId;
    store.failNextCreate =
        const StoreException(StoreErrorKind.outcomeUnknown, 'cancelled');
    await controller.submit();
    expect(controller.phase, QuizPhase.saveUnknown);

    store.failNextRead =
        const StoreException(StoreErrorKind.unavailable, 'unavailable');
    await controller.resolveUnknown();
    expect(controller.phase, QuizPhase.saveUnknown, reason: 'still offline');

    await controller.resolveUnknown();
    expect(controller.phase, QuizPhase.readyToSubmit);
    expect(controller.roundId, roundId);

    await controller.submit();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(store.docCount('userA'), 1);
    expect(store.docs.keys.single, 'users/userA/attempts/$roundId');
  });

  test('denied, unavailable and exhausted are distinct and never loop',
      () async {
    await playRound(controller, correct: 3);
    final roundId = controller.roundId;

    store.failNextCreate = const StoreException(
      StoreErrorKind.permissionDenied,
      'permission-denied',
    );
    await controller.submit();
    expect(controller.phase, QuizPhase.permissionDenied);

    store.failNextCreate =
        const StoreException(StoreErrorKind.unavailable, 'unavailable');
    await controller.submit();
    expect(controller.phase, QuizPhase.saveFailed);
    expect(controller.failureKind, StoreErrorKind.unavailable);

    store.failNextCreate = const StoreException(
      StoreErrorKind.resourceExhausted,
      'resource-exhausted',
    );
    await controller.submit();
    expect(controller.phase, QuizPhase.saveFailed);
    expect(controller.failureKind, StoreErrorKind.resourceExhausted);
    expect(store.createCalls, 3, reason: 'only user-triggered attempts');
    expect(store.docCount('userA'), 0, reason: 'no false success');

    await controller.submit();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(controller.roundId, roundId);
    expect(store.docCount('userA'), 1);
  });

  test('a failed verification read is not a failed save', () async {
    await playRound(controller, correct: 9);
    store.failNextRead =
        const StoreException(StoreErrorKind.unavailable, 'unavailable');
    await controller.submit();

    expect(controller.phase, QuizPhase.verificationUnavailable);
    expect(store.docCount('userA'), 1);
    expect(controller.canSubmit, isFalse);
    expect(controller.canStartRound, isFalse);

    await controller.retryVerification();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(store.createCalls, 1, reason: 'verification never writes');
  });

  test('same ID with a different score is a collision, original kept',
      () async {
    await playRound(controller, correct: 2);
    final key = store.path('userA', controller.roundId!);
    store.docs[key] = <String, dynamic>{
      ...const AttemptPayload(correctCount: 10).fixedFields,
      'submittedAt': DateTime.utc(2026, 11, 16, 19),
    };

    await controller.submit();
    expect(controller.phase, QuizPhase.collision);
    expect(store.docs[key]?['correctCount'], 10);
    expect(store.docCount('userA'), 1);
  });

  test('same ID and same payload reuses the existing document', () async {
    await playRound(controller, correct: 2);
    final key = store.path('userA', controller.roundId!);
    store.docs[key] = <String, dynamic>{
      ...const AttemptPayload(correctCount: 2).fixedFields,
      'submittedAt': DateTime.utc(2026, 11, 16, 19),
    };

    await controller.submit();
    expect(controller.phase, QuizPhase.cloudVerified);
    expect(controller.outcome, SaveOutcome.matchedExisting);
    expect(store.docCount('userA'), 1);
  });

  test('a response for the previous user never reaches the new user',
      () async {
    await playRound(controller, correct: 5);
    final hold = Completer<void>();
    store.holdCreate = hold;
    final pending = controller.submit();
    await pumpEventQueue();
    expect(controller.phase, QuizPhase.submitting);

    // Authentication changes outside the app while the save is in flight.
    auth.emit(const AuthUser(uid: 'userB', email: 'b@example.com'));
    expect(controller.phase, QuizPhase.home);

    hold.complete();
    await pending;
    expect(controller.uid, 'userB');
    expect(controller.phase, QuizPhase.home);
    expect(controller.verified, isNull);
    expect(controller.roundId, isNull);
  });

  test('sign-out is refused while a submission is unresolved', () async {
    await playRound(controller, correct: 5);
    store.dropNextAck = true;
    await controller.submit();
    expect(controller.phase, QuizPhase.saveUnknown);

    await controller.signOut();
    expect(controller.uid, 'userA');
    expect(controller.phase, QuizPhase.saveUnknown);

    await controller.resolveUnknown();
    await controller.signOut();
    expect(controller.uid, isNull);
    expect(controller.phase, QuizPhase.signedOut);
  });
}
