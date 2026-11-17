import 'package:flutter/material.dart';

import '../app.dart';
import '../state/quiz_controller.dart';
import '../widgets/common.dart';

/// Loading, request error, and the question being played.
class PlayScreen extends StatelessWidget {
  const PlayScreen({super.key, required this.deps});

  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    final controller = deps.controller;
    final Widget body;
    switch (controller.phase) {
      case QuizPhase.loading:
        body = _Loading(controller: controller);
      case QuizPhase.requestError:
        body = _RequestError(controller: controller);
      default:
        body = _QuestionView(controller: controller);
    }
    return QuizScaffold(deps: deps, title: 'Quiz', body: body);
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.controller});

  final QuizController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        StatusBanner(
          icon: Icons.downloading,
          color: kInfoColor,
          busy: true,
          title: 'Loading questions',
          detail: 'Asking the question service for 10 easy General Knowledge '
              'questions. Round ${controller.shownId(controller.roundId)}.',
        ),
      ],
    );
  }
}

class _RequestError extends StatelessWidget {
  const _RequestError({required this.controller});

  final QuizController controller;

  @override
  Widget build(BuildContext context) {
    final wait = controller.cooldownSeconds;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        StatusBanner(
          icon: Icons.error_outline,
          color: kWrongColor,
          title: 'Questions could not be loaded',
          detail: '${controller.message ?? 'Unknown error.'}\n'
              'No round was started.',
          injected: controller.injected,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: controller.canStartRound ? controller.startRound : null,
          child: Text(wait > 0 ? 'Retry allowed in $wait s' : 'Retry now'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: controller.canGoHome ? controller.goHome : null,
          child: const Text('Back to home'),
        ),
      ],
    );
  }
}

enum _ChoiceState { idle, pickedCorrect, pickedWrong, revealedCorrect, dimmed }

class _QuestionView extends StatelessWidget {
  const _QuestionView({required this.controller});

  final QuizController controller;

  _ChoiceState _stateFor(int choice, int? selected, int correct) {
    if (selected == null) {
      return _ChoiceState.idle;
    }
    if (choice == selected) {
      return choice == correct
          ? _ChoiceState.pickedCorrect
          : _ChoiceState.pickedWrong;
    }
    return choice == correct
        ? _ChoiceState.revealedCorrect
        : _ChoiceState.dimmed;
  }

  @override
  Widget build(BuildContext context) {
    final question = controller.currentQuestion;
    final selected = controller.currentSelection;
    final answered = selected != null;
    final total = controller.questions.length;
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Question ${controller.index + 1} of $total',
                style: text.titleMedium,
              ),
            ),
            Text('Score: ${controller.score}', style: text.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: (controller.index + (answered ? 1 : 0)) / total,
        ),
        const SizedBox(height: 4),
        Text(
          'Round ${controller.shownId(controller.roundId)}',
          style: text.bodySmall,
        ),
        const SizedBox(height: 16),
        Text(question.text, style: text.titleLarge),
        const SizedBox(height: 12),
        for (var i = 0; i < question.choices.length; i++)
          _ChoiceTile(
            number: i + 1,
            text: question.choices[i],
            state: _stateFor(i, selected, question.correctIndex),
            // Once answered, the other taps are disabled.
            onTap: answered ? null : () => controller.answer(i),
          ),
        const SizedBox(height: 8),
        if (!answered)
          const StatusBanner(
            icon: Icons.touch_app_outlined,
            color: kInfoColor,
            title: 'Choose one answer',
            detail: 'Your first tap is final for this question.',
          )
        else if (selected == question.correctIndex)
          const StatusBanner(
            icon: Icons.check_circle,
            color: kCorrectColor,
            title: 'Correct: +1 point',
          )
        else
          StatusBanner(
            icon: Icons.cancel,
            color: kWrongColor,
            title: 'Incorrect: no point',
            detail: 'The answer was: ${question.correctAnswer}',
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: answered ? controller.next : null,
          child: Text(
            controller.isLastQuestion ? 'See results' : 'Next question',
          ),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.number,
    required this.text,
    required this.state,
    required this.onTap,
  });

  final int number;
  final String text;
  final _ChoiceState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final Color color;
    final IconData? icon;
    final String note;
    switch (state) {
      case _ChoiceState.idle:
        color = scheme.outline;
        icon = null;
        note = '';
      case _ChoiceState.pickedCorrect:
        color = kCorrectColor;
        icon = Icons.check_circle;
        note = 'your answer, correct';
      case _ChoiceState.pickedWrong:
        color = kWrongColor;
        icon = Icons.cancel;
        note = 'your answer, incorrect';
      case _ChoiceState.revealedCorrect:
        color = kCorrectColor;
        icon = Icons.check_circle_outline;
        note = 'the right answer';
      case _ChoiceState.dimmed:
        color = scheme.outlineVariant;
        icon = null;
        note = '';
    }
    final highlighted = icon != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        container: true,
        button: true,
        enabled: onTap != null,
        label: 'Choice $number: $text${note.isEmpty ? '' : ' ($note)'}',
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: highlighted
              ? color.withValues(alpha: 0.10)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: color, width: highlighted ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Text(
                      String.fromCharCode(64 + number),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(text, style: textTheme.bodyLarge),
                        if (note.isNotEmpty)
                          Text(
                            note,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (icon != null) Icon(icon, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
