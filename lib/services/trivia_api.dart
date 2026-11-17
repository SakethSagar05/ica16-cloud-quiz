import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/question.dart';
import 'fault_switches.dart';

/// Supplies one validated round of questions.
abstract class TriviaApi {
  Future<List<Question>> fetchRound();
}

/// Open Trivia Database over HTTP GET. It only supplies questions; it never
/// receives scores.
class OpenTdbApi implements TriviaApi {
  OpenTdbApi({http.Client? client, FaultSwitches? faults})
      : _client = client ?? http.Client(),
        _faults = faults;

  final http.Client _client;
  final FaultSwitches? _faults;

  @override
  Future<List<Question>> fetchRound() async {
    final fault = _faults?.takeQuestionFault() ?? QuestionFault.none;
    if (fault != QuestionFault.none) {
      // Development only: skip the network and feed a bad body through the
      // real validation, so the test exercises the same code as production.
      try {
        return parseRound(injectedBody(fault));
      } on TriviaException catch (e) {
        throw e.asInjected();
      }
    }

    final response = await _get();
    if (response.statusCode == 429) {
      throw const TriviaException(
        TriviaErrorKind.rateLimited,
        'The question service is rate limiting this device (HTTP 429). '
        'Wait at least five seconds, then retry.',
      );
    }
    if (response.statusCode != 200) {
      throw TriviaException(
        TriviaErrorKind.httpStatus,
        'The question service answered with HTTP ${response.statusCode}.',
      );
    }
    // HTTP 200 only means a body arrived. parseRound checks the API code and
    // the schema before anything becomes playable.
    return parseRound(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  Future<http.Response> _get() async {
    try {
      return await _client
          .get(QuizConfig.questionsUri)
          .timeout(QuizConfig.httpTimeout);
    } on TimeoutException {
      throw const TriviaException(
        TriviaErrorKind.timeout,
        'The question service did not answer within 10 seconds.',
      );
    } on Exception {
      throw const TriviaException(
        TriviaErrorKind.network,
        'Could not reach the question service. Check the connection.',
      );
    }
  }
}

/// Bodies used by the fault lab for test T03.
String injectedBody(QuestionFault fault) {
  switch (fault) {
    case QuestionFault.badJson:
      return '{"response_code":0,"results":[{"type":"multiple","difficulty"';
    case QuestionFault.apiCode:
      return '{"response_code":1,"results":[]}';
    case QuestionFault.nineResults:
      return jsonEncode(<String, Object>{
        'response_code': 0,
        'results': <Map<String, Object>>[
          for (var i = 1; i <= 9; i++)
            <String, Object>{
              'type': QuizConfig.questionType,
              'difficulty': QuizConfig.difficulty,
              'category': QuizConfig.categoryName,
              'question': 'Injected question $i?',
              'correct_answer': 'Right $i',
              'incorrect_answers': <String>[
                'Wrong ${i}a',
                'Wrong ${i}b',
                'Wrong ${i}c',
              ],
            },
        ],
      });
    case QuestionFault.none:
      return '';
  }
}
