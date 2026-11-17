import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/play_screen.dart';
import 'screens/review_screen.dart';
import 'screens/sign_in_screen.dart';
import 'services/attempt_store.dart';
import 'services/fault_switches.dart';
import 'state/quiz_controller.dart';
import 'util/event_log.dart';

/// Everything the screens need, created once in main().
class AppDeps {
  const AppDeps({
    required this.controller,
    required this.store,
    required this.log,
    this.faults,
  });

  final QuizController controller;
  final AttemptStore store;
  final EventLog log;

  /// Null in release builds: the fault lab is not compiled in.
  final FaultSwitches? faults;
}

ThemeData buildTheme() {
  return ThemeData(
    colorSchemeSeed: const Color(0xFF5633C9),
    useMaterial3: true,
  );
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key, required this.deps});

  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ICA16 Cloud Quiz',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: RootScreen(deps: deps),
    );
  }
}

/// Shows the screen that belongs to the current phase.
class RootScreen extends StatelessWidget {
  const RootScreen({super.key, required this.deps});

  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: deps.controller,
      builder: (context, _) {
        switch (deps.controller.phase) {
          case QuizPhase.signedOut:
          case QuizPhase.authError:
            return SignInScreen(controller: deps.controller);
          case QuizPhase.home:
            return HomeScreen(deps: deps);
          case QuizPhase.loading:
          case QuizPhase.requestError:
          case QuizPhase.playing:
            return PlayScreen(deps: deps);
          case QuizPhase.readyToSubmit:
          case QuizPhase.submitting:
          case QuizPhase.verifying:
          case QuizPhase.cloudVerified:
          case QuizPhase.saveUnknown:
          case QuizPhase.permissionDenied:
          case QuizPhase.saveFailed:
          case QuizPhase.collision:
          case QuizPhase.verificationUnavailable:
            return ReviewScreen(deps: deps);
        }
      },
    );
  }
}

/// Shown when Firebase could not be initialized (bad or missing config).
class FirebaseInitErrorApp extends StatelessWidget {
  const FirebaseInitErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'The app could not connect to Firebase.\n'
              'Check the connection and restart the app.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
