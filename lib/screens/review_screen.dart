import 'package:flutter/material.dart';

import '../app.dart';
import '../config.dart';
import '../models/question.dart';
import '../services/attempt_store.dart';
import '../state/quiz_controller.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

/// Final score, the review of all ten answers, and the cloud save with every
/// one of its states.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.deps});

  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    final controller = deps.controller;
    final text = Theme.of(context).textTheme;
    final verified = controller.verified;
    final selections = controller.selections;
    return QuizScaffold(
      deps: deps,
      title: 'Results',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Final score: ${controller.score} / ${QuizConfig.questionCount}',
            style: text.headlineMedium,
          ),
          const SizedBox(height: 4),
          Text('Round ${controller.shownId(controller.roundId)}'),
          const SizedBox(height: 12),
          _banner(controller),
          const SizedBox(height: 12),
          ..._actions(context, controller),
          if (verified != null) ...<Widget>[
            const SizedBox(height: 12),
            AttemptCard(attempt: verified, controller: controller),
          ],
          const Divider(height: 32),
          Text(
            'Review of all ${controller.questions.length} answers',
            style: text.titleMedium,
          ),
          for (var i = 0; i < controller.questions.length; i++)
            _ReviewTile(
              number: i + 1,
              question: controller.questions[i],
              selection: selections[i],
            ),
        ],
      ),
    );
  }

  Widget _banner(QuizController c) {
    switch (c.phase) {
      case QuizPhase.readyToSubmit:
        return StatusBanner(
          icon: Icons.cloud_upload_outlined,
          color: kInfoColor,
          title: 'Not saved yet',
          detail: c.message ??
              'Submit to save this attempt to your cloud account.',
        );
      case QuizPhase.submitting:
        return const StatusBanner(
          icon: Icons.cloud_upload_outlined,
          color: kInfoColor,
          busy: true,
          title: 'Saving to the cloud',
          detail: 'Running the create-once transaction for this round.',
        );
      case QuizPhase.verifying:
        return const StatusBanner(
          icon: Icons.cloud_sync_outlined,
          color: kInfoColor,
          busy: true,
          title: 'Checking the server',
          detail: 'Reading this exact document from the server, not from '
              'the cache.',
        );
      case QuizPhase.cloudVerified:
        final how = c.recovered
            ? 'Recovered by a server read after an unknown result. No second '
                'document was written.'
            : (c.outcome == SaveOutcome.matchedExisting
                ? 'An identical attempt already existed for this round, so '
                    'it was reused. Nothing was written twice.'
                : 'The server returned this attempt with its own timestamp.');
        return StatusBanner(
          icon: Icons.cloud_done,
          color: kCorrectColor,
          title: 'Cloud verified',
          detail: how,
        );
      case QuizPhase.saveUnknown:
        return StatusBanner(
          icon: Icons.help_outline,
          color: kWarnColor,
          title: 'Save status unknown',
          detail: c.message,
          injected: c.injected,
        );
      case QuizPhase.verificationUnavailable:
        return StatusBanner(
          icon: Icons.cloud_sync_outlined,
          color: kWarnColor,
          title: 'Verification unavailable',
          detail: c.message,
          injected: c.injected,
        );
      case QuizPhase.permissionDenied:
        return StatusBanner(
          icon: Icons.lock_outline,
          color: kWrongColor,
          title: 'Permission denied',
          detail: c.message,
          injected: c.injected,
        );
      case QuizPhase.collision:
        return StatusBanner(
          icon: Icons.report_problem_outlined,
          color: kWrongColor,
          title: 'Round ID collision',
          detail: c.message,
          injected: c.injected,
        );
      case QuizPhase.saveFailed:
        final IconData icon;
        final String title;
        switch (c.failureKind) {
          case StoreErrorKind.unavailable:
            icon = Icons.cloud_off;
            title = 'Cloud unavailable';
          case StoreErrorKind.resourceExhausted:
            icon = Icons.hourglass_disabled;
            title = 'Quota exhausted';
          case StoreErrorKind.unauthenticated:
            icon = Icons.no_accounts_outlined;
            title = 'Not authenticated';
          default:
            icon = Icons.error_outline;
            title = 'Save failed';
        }
        return StatusBanner(
          icon: icon,
          color: kWrongColor,
          title: title,
          detail: c.message,
          injected: c.injected,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  List<Widget> _actions(BuildContext context, QuizController c) {
    final wait = c.cooldownSeconds;
    final replay = OutlinedButton(
      onPressed: c.canStartRound ? c.startRound : null,
      child: Text(wait > 0 ? 'Replay allowed in $wait s' : 'Play again'),
    );
    final home = TextButton(
      onPressed: c.canGoHome ? c.goHome : null,
      child: const Text('Back to home'),
    );
    const gap = SizedBox(height: 8);

    switch (c.phase) {
      case QuizPhase.readyToSubmit:
        return <Widget>[
          FilledButton(
            onPressed: c.canSubmit ? c.submit : null,
            child: const Text('Submit score to cloud'),
          ),
          gap,
          replay,
          home,
        ];
      case QuizPhase.submitting:
      case QuizPhase.verifying:
        return const <Widget>[
          FilledButton(onPressed: null, child: Text('Working')),
          gap,
          Text('Replay and sign-out are disabled until this is resolved.'),
        ];
      case QuizPhase.saveUnknown:
        return <Widget>[
          FilledButton(
            onPressed: c.resolveUnknown,
            child: const Text('Check the cloud'),
          ),
          gap,
          Text(
            c.saveSettled
                ? 'The earlier save operation has finished. A server read '
                    'will show whether it was committed.'
                : 'The earlier save operation is still running in the '
                    'background.',
          ),
          gap,
          const Text(
            'Replay and sign-out are disabled until this is resolved.',
          ),
        ];
      case QuizPhase.verificationUnavailable:
        return <Widget>[
          FilledButton(
            onPressed: c.retryVerification,
            child: const Text('Retry verification'),
          ),
          gap,
          const Text(
            'Replay and sign-out are disabled until this is resolved.',
          ),
        ];
      case QuizPhase.permissionDenied:
      case QuizPhase.saveFailed:
        return <Widget>[
          FilledButton(
            onPressed: c.canSubmit ? c.submit : null,
            child: const Text('Retry save (same round ID)'),
          ),
          gap,
          replay,
          home,
        ];
      case QuizPhase.cloudVerified:
        return <Widget>[
          replay,
          gap,
          OutlinedButton(
            onPressed: () => openAttempts(context, deps),
            child: const Text('My cloud attempts'),
          ),
          home,
        ];
      case QuizPhase.collision:
        return <Widget>[replay, home];
      default:
        return const <Widget>[];
    }
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({
    required this.number,
    required this.question,
    required this.selection,
  });

  final int number;
  final Question question;
  final int? selection;

  @override
  Widget build(BuildContext context) {
    final picked = selection;
    final answer = picked == null ? 'no answer' : question.choices[picked];
    final correct = answer == question.correctAnswer;
    final color = correct ? kCorrectColor : kWrongColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(correct ? Icons.check_circle : Icons.cancel, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Q$number. ${question.text}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'You chose: $answer '
                  '(${correct ? 'correct' : 'incorrect'})',
                  style: TextStyle(color: color),
                ),
                if (!correct) Text('Answer: ${question.correctAnswer}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
