import 'package:flutter/foundation.dart';

/// Class A constants. The same values appear in the request URL, in the
/// response validation and in the cloud document, so they live in one place.
class QuizConfig {
  static const String variant = 'A';
  static const int schemaVersion = 1;
  static const int categoryId = 9;
  static const String categoryName = 'General Knowledge';
  static const String difficulty = 'easy';
  static const String questionType = 'multiple';
  static const int questionCount = 10;

  /// The exact Class A request.
  static final Uri questionsUri = Uri.parse(
    'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple',
  );

  /// How long the app waits for the question service.
  static const Duration httpTimeout = Duration(seconds: 10);

  /// OpenTDB allows one request every five seconds per device.
  static const Duration minRequestGap = Duration(seconds: 5);

  /// How long the UI waits for the save before it reports "unknown".
  /// Reaching this limit does not cancel the save or prove it failed.
  static const Duration saveUiTimeout = Duration(seconds: 10);

  /// How long the UI waits for the server-only verification read.
  static const Duration verifyTimeout = Duration(seconds: 10);
}

/// Development-only fault lab (question faults, save faults, rule probes).
/// On in debug builds, off in release builds unless the build passes
/// `--dart-define=ICA16_DEV_TOOLS=true`.
const bool kDevTools =
    bool.fromEnvironment('ICA16_DEV_TOOLS', defaultValue: kDebugMode);

/// Short git commit of the build, passed with `--dart-define=GIT_COMMIT=...`.
const String kGitCommit =
    String.fromEnvironment('GIT_COMMIT', defaultValue: 'local');
