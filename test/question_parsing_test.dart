import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ica16_cloud_quiz/models/question.dart';
import 'package:ica16_cloud_quiz/services/fault_switches.dart';
import 'package:ica16_cloud_quiz/services/trivia_api.dart';

Map<String, Object> item(
  int i, {
  String category = 'General Knowledge',
  String difficulty = 'easy',
  String type = 'multiple',
  String? question,
  String? correct,
  List<String>? incorrect,
}) {
  return <String, Object>{
    'type': type,
    'difficulty': difficulty,
    'category': category,
    'question': question ?? 'Question $i?',
    'correct_answer': correct ?? 'Right $i',
    'incorrect_answers':
        incorrect ?? <String>['Wrong ${i}a', 'Wrong ${i}b', 'Wrong ${i}c'],
  };
}

String body({int code = 0, List<Map<String, Object>>? items}) {
  return jsonEncode(<String, Object>{
    'response_code': code,
    'results': items ??
        <Map<String, Object>>[for (var i = 1; i <= 10; i++) item(i)],
  });
}

/// Ten valid items with item number 1 replaced by [first].
List<Map<String, Object>> withFirst(Map<String, Object> first) {
  return <Map<String, Object>>[
    first,
    for (var i = 2; i <= 10; i++) item(i),
  ];
}

Matcher throwsTrivia(TriviaErrorKind kind) {
  return throwsA(
    isA<TriviaException>().having((e) => e.kind, 'kind', kind),
  );
}

void main() {
  group('parseRound accepts a valid Class A round', () {
    test('returns exactly ten questions with four choices each', () {
      final round = parseRound(body(), random: Random(1));
      expect(round, hasLength(10));
      for (final question in round) {
        expect(question.choices, hasLength(4));
        expect(question.choices.toSet(), hasLength(4));
        expect(question.choices, contains(question.correctAnswer));
        expect(question.correctIndex, inInclusiveRange(0, 3));
      }
    });

    test('decodes HTML entities in the question and the answers', () {
      final round = parseRound(
        body(
          items: withFirst(
            item(
              1,
              question: 'What is &quot;H&#039;s&quot; &amp; why?',
              correct: 'Caf&eacute;',
              incorrect: <String>['A &lt; B', 'Rock &amp; Roll', 'It&#039;s'],
            ),
          ),
        ),
      );
      expect(round.first.text, 'What is "H\'s" & why?');
      expect(round.first.correctAnswer, 'Café');
      expect(
        round.first.choices,
        containsAll(<String>['Café', 'A < B', 'Rock & Roll', "It's"]),
      );
    });

    test('the choice order is fixed once the round is parsed', () {
      final round = parseRound(body(), random: Random(7));
      final before = List<String>.of(round.first.choices);
      // Reading the list again (as build() does) never reshuffles it.
      expect(round.first.choices, before);
      expect(identical(round.first.choices, round.first.choices), isTrue);
    });
  });

  group('parseRound blocks play on bad data', () {
    test('malformed JSON', () {
      expect(
        () => parseRound('{"response_code":0,"results":['),
        throwsTrivia(TriviaErrorKind.malformedJson),
      );
    });

    test('HTTP 200 with a nonzero API code', () {
      expect(
        () => parseRound(body(code: 1, items: <Map<String, Object>>[])),
        throwsTrivia(TriviaErrorKind.apiCode),
      );
    });

    test('nine results', () {
      expect(
        () => parseRound(
          body(
            items: <Map<String, Object>>[
              for (var i = 1; i <= 9; i++) item(i),
            ],
          ),
        ),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });

    test('empty results with code 0', () {
      expect(
        () => parseRound(body(items: <Map<String, Object>>[])),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });

    test('wrong category, difficulty or type', () {
      expect(
        () => parseRound(body(items: withFirst(item(1, category: 'History')))),
        throwsTrivia(TriviaErrorKind.schema),
      );
      expect(
        () => parseRound(body(items: withFirst(item(1, difficulty: 'hard')))),
        throwsTrivia(TriviaErrorKind.schema),
      );
      expect(
        () => parseRound(body(items: withFirst(item(1, type: 'boolean')))),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });

    test('two incorrect answers instead of three', () {
      expect(
        () => parseRound(
          body(items: withFirst(item(1, incorrect: <String>['a', 'b']))),
        ),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });

    test('empty question or empty choice after decoding', () {
      expect(
        () => parseRound(body(items: withFirst(item(1, question: '   ')))),
        throwsTrivia(TriviaErrorKind.schema),
      );
      expect(
        () => parseRound(
          body(items: withFirst(item(1, incorrect: <String>['a', '', 'c']))),
        ),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });

    test('choices that are duplicates once decoded', () {
      expect(
        () => parseRound(
          body(
            items: withFirst(
              item(
                1,
                correct: 'Rock & Roll',
                incorrect: <String>['Rock &amp; Roll', 'Jazz', 'Blues'],
              ),
            ),
          ),
        ),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });
  });

  group('fault lab bodies go through the same validation', () {
    test('each injected body is rejected with the expected kind', () {
      expect(
        () => parseRound(injectedBody(QuestionFault.badJson)),
        throwsTrivia(TriviaErrorKind.malformedJson),
      );
      expect(
        () => parseRound(injectedBody(QuestionFault.apiCode)),
        throwsTrivia(TriviaErrorKind.apiCode),
      );
      expect(
        () => parseRound(injectedBody(QuestionFault.nineResults)),
        throwsTrivia(TriviaErrorKind.schema),
      );
    });
  });
}
