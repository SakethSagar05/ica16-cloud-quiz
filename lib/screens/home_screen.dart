import 'package:flutter/material.dart';

import '../app.dart';
import '../config.dart';
import '../widgets/common.dart';
import 'attempts_screen.dart';

/// Signed-in start point: who is signed in, start a round, or look at the
/// attempts the server already holds (without playing again).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.deps});

  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    final controller = deps.controller;
    final text = Theme.of(context).textTheme;
    final wait = controller.cooldownSeconds;
    return QuizScaffold(
      deps: deps,
      title: 'Home',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          StatusBanner(
            icon: Icons.verified_user_outlined,
            color: kInfoColor,
            title: 'Signed in',
            detail: '${controller.email ?? 'account'}\n'
                'UID ${controller.shownId(controller.uid)}',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: controller.toggleFullIds,
              child: Text(
                controller.showFullIds ? 'Hide full IDs' : 'Show full IDs',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('General Knowledge', style: text.headlineSmall),
          const Text('10 easy multiple-choice questions. One answer each.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: controller.canStartRound ? controller.startRound : null,
            child: Text(
              wait > 0 ? 'Next request allowed in $wait s' : 'Start round',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => openAttempts(context, deps),
            child: const Text('My cloud attempts'),
          ),
          const SizedBox(height: 24),
          Text(
            'Build $kGitCommit, '
            '${kDevTools ? 'fault lab available' : 'release'}',
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

void openAttempts(BuildContext context, AppDeps deps) {
  final uid = deps.controller.uid;
  if (uid == null) {
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AttemptsScreen(deps: deps, uid: uid),
    ),
  );
}
