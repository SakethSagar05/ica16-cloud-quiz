import 'package:flutter/material.dart';

import '../app.dart';
import '../models/attempt.dart';
import '../screens/dev_lab_screen.dart';
import '../state/quiz_controller.dart';
import '../util/event_log.dart';

// Feedback colors. Each one is always paired with an icon and text, so the
// meaning never depends on color alone.
const Color kCorrectColor = Color(0xFF2E7D32);
const Color kWrongColor = Color(0xFFC62828);
const Color kWarnColor = Color(0xFFB26A00);
const Color kInfoColor = Color(0xFF5633C9);

/// One visual cue per state: an icon (or a spinner while work is running),
/// a title and one line of detail.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.detail,
    this.busy = false,
    this.injected = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
  final bool busy;
  final bool injected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final detail = this.detail;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (busy)
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3, color: color),
            )
          else
            Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: text.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (injected)
                  Text(
                    'INJECTED FAULT (development only)',
                    style: text.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (detail != null && detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(detail),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// App bar shared by the signed-in screens: fault lab (development builds
/// only) and sign-out, which is disabled while a submission is unresolved.
class QuizScaffold extends StatelessWidget {
  const QuizScaffold({
    super.key,
    required this.deps,
    required this.title,
    required this.body,
  });

  final AppDeps deps;
  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final controller = deps.controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: <Widget>[
          if (deps.faults != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DevLabScreen(deps: deps),
                  ),
                );
              },
              child: const Text('Fault lab'),
            ),
          TextButton(
            onPressed: controller.canSignOut ? controller.signOut : null,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

/// The six fields of one attempt, as the server returned them.
class AttemptCard extends StatelessWidget {
  const AttemptCard({
    super.key,
    required this.attempt,
    required this.controller,
  });

  final ServerAttempt attempt;
  final QuizController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Document read from the server', style: text.titleSmall),
            const SizedBox(height: 8),
            SelectableText('Path: ${controller.shownPath(attempt.path)}'),
            for (final name in AttemptPayload.fixedFieldNames)
              Text('$name: ${attempt.data[name]}'),
            Text('submittedAt: ${formatStamp(attempt.submittedAt)}'),
            const SizedBox(height: 8),
            Text(
              'Read source: ${attempt.fromCache ? 'CACHE' : 'server'}, '
              'pending writes: ${attempt.hasPendingWrites ? 'yes' : 'none'}',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
