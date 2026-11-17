import 'dart:convert';
import 'dart:math';

import 'package:html_unescape/html_unescape.dart';

import '../config.dart';

/// Why a round could not be loaded. `malformedJson`, `apiCode` and `schema`
/// are three different layers: the HTTP call can succeed (status 200) while
/// any of them still fails.
enum TriviaErrorKind {
  network,
  timeout,
  httpStatus,
  rateLimited,
  malformedJson,
  apiCode,
  schema,
}

class TriviaException implements Exception {
  const TriviaException(this.kind, this.message, {this.injected = false});

  final TriviaErrorKind kind;
  final String message;

  /// True when the fault lab produced this error on purpose.
  final bool injected;

  TriviaException asInjected() =>
      TriviaException(kind, message, injected: true);

  @override
  String toString() => 'TriviaException(${kind.name}): $message';
}

/// One validated multiple-choice question.
class Question {
  const Question({
    required this.text,
    required this.correctAnswer,
    required this.choices,
  });

  final String text;
  final String correctAnswer;

  /// The four choices, shuffled exactly once when the round was parsed.
  /// Widgets read this list; they never shuffle inside `build()`.
  final List<String> choices;

  int get correctIndex => choices.indexOf(correctAnswer);
}

TriviaException _schema(String detail) => TriviaException(
      TriviaErrorKind.schema,
      'The question service sent a round this app cannot use: $detail',
    );

Object? _decodeJson(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw const TriviaException(
      TriviaErrorKind.malformedJson,
      'The question service sent data that is not valid JSON.',
    );
  }
}

String _apiCodeMeaning(int code) {
  switch (code) {
    case 1:
      return 'no results for this request';
    case 2:
      return 'invalid parameter';
    case 3:
      return 'session token not found';
    case 4:
      return 'session token exhausted';
    case 5:
      return 'too many requests, wait five seconds';
    default:
      return 'unknown code';
  }
}

/// Turns one HTTP 200 body into exactly ten playable questions, or throws a
/// [TriviaException]. Nothing partial is ever returned.
///
/// Checks, in order: valid JSON, `response_code == 0`, exactly ten results,
/// then per result the Class A category, difficulty and type, a nonempty
/// question, a nonempty correct answer and exactly three nonempty incorrect
/// answers, with all four decoded choices different from each other.
List<Question> parseRound(String body, {Random? random}) {
  final decoded = _decodeJson(body);
  if (decoded is! Map<String, dynamic>) {
    throw _schema('the top level is not a JSON object.');
  }
  final code = decoded['response_code'];
  if (code is! int) {
    throw _schema('response_code is missing.');
  }
  if (code != 0) {
    throw TriviaException(
      TriviaErrorKind.apiCode,
      'The question service answered with API code $code '
      '(${_apiCodeMeaning(code)}), so there are no questions to play.',
    );
  }
  final results = decoded['results'];
  if (results is! List) {
    throw _schema('the results list is missing.');
  }
  if (results.length != QuizConfig.questionCount) {
    throw _schema(
      'expected ${QuizConfig.questionCount} questions but received '
      '${results.length}.',
    );
  }

  final unescape = HtmlUnescape();
  final rng = random ?? Random();
  final questions = <Question>[];

  for (var i = 0; i < results.length; i++) {
    final raw = results[i];
    final label = 'question ${i + 1}';
    if (raw is! Map<String, dynamic>) {
      throw _schema('$label is not a JSON object.');
    }

    String text(String key) {
      final value = raw[key];
      if (value is! String) {
        throw _schema('$label has no "$key" text.');
      }
      final clean = unescape.convert(value).trim();
      if (clean.isEmpty) {
        throw _schema('$label has an empty "$key".');
      }
      return clean;
    }

    if (text('type') != QuizConfig.questionType) {
      throw _schema('$label is not multiple choice.');
    }
    if (text('difficulty') != QuizConfig.difficulty) {
      throw _schema('$label is not easy difficulty.');
    }
    if (text('category') != QuizConfig.categoryName) {
      throw _schema('$label is not in ${QuizConfig.categoryName}.');
    }

    final question = text('question');
    final correct = text('correct_answer');

    final wrongRaw = raw['incorrect_answers'];
    if (wrongRaw is! List || wrongRaw.length != 3) {
      throw _schema('$label does not have exactly three incorrect answers.');
    }
    final choices = <String>[correct];
    for (final item in wrongRaw) {
      if (item is! String) {
        throw _schema('$label has an incorrect answer that is not text.');
      }
      final clean = unescape.convert(item).trim();
      if (clean.isEmpty) {
        throw _schema('$label has an empty answer choice.');
      }
      choices.add(clean);
    }
    if (choices.toSet().length != choices.length) {
      throw _schema('$label has duplicate answer choices.');
    }

    choices.shuffle(rng);
    questions.add(
      Question(
        text: question,
        correctAnswer: correct,
        choices: List<String>.unmodifiable(choices),
      ),
    );
  }
  return List<Question>.unmodifiable(questions);
}
