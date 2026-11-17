import 'package:flutter/material.dart';

import '../app.dart';
import '../services/fault_switches.dart';
import '../services/rule_probes.dart';
import '../util/event_log.dart';
import '../widgets/common.dart';

/// Development-only fault lab. It is reachable only when the build was made
/// with the fault lab compiled in (debug, or ICA16_DEV_TOOLS=true).
///
/// - Question faults feed a bad body through the real validation (T03).
/// - Save faults drop the acknowledgement of a real commit (T09) or model a
///   backend error without sending anything (T12).
/// - Rule probes send deliberately invalid requests to the deployed rules
///   (T10, T11).
class DevLabScreen extends StatefulWidget {
  const DevLabScreen({super.key, required this.deps});

  final AppDeps deps;

  @override
  State<DevLabScreen> createState() => _DevLabScreenState();
}

class _DevLabScreenState extends State<DevLabScreen> {
  final RuleProbes _probes = RuleProbes();
  final ScrollController _scroll = ScrollController();
  // Optional manual overrides. When they are empty, the probes use the
  // attempts that were cloud verified during this app session (memory only),
  // so full IDs never have to be shown on screen.
  final TextEditingController _otherUid = TextEditingController();
  final TextEditingController _otherRound = TextEditingController();
  final TextEditingController _myRound = TextEditingController();
  final List<ProbeResult> _results = <ProbeResult>[];
  bool _running = false;

  @override
  void dispose() {
    _scroll.dispose();
    _otherUid.dispose();
    _otherRound.dispose();
    _myRound.dispose();
    super.dispose();
  }

  ProbeResult _skipped(String label, String why) =>
      ProbeResult(label: label, passed: false, detail: 'not run: $why');

  Future<void> _run(Future<List<ProbeResult>> Function() body) async {
    if (_running) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _running = true);
    List<ProbeResult> results;
    try {
      results = await body();
    } catch (e) {
      results = <ProbeResult>[
        _skipped('probe', 'unexpected error ${e.runtimeType}'),
      ];
    }
    for (final result in results) {
      widget.deps.log.add(
        'probe ${result.label}: '
        '${result.passed ? 'DENIED as expected' : 'NOT DENIED'} '
        '(${result.detail})',
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _results.insertAll(0, results);
      _running = false;
    });
    // Results are listed at the top of the screen.
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  Future<List<ProbeResult>> _runT10() async {
    final session = widget.deps.controller.lastVerifiedOtherUser;
    final typedUid = _otherUid.text.trim();
    final typedRound = _otherRound.text.trim();
    final uid = typedUid.isNotEmpty ? typedUid : (session?.uid ?? '');
    final round = typedRound.isNotEmpty ? typedRound : (session?.roundId ?? '');
    if (uid.isEmpty || round.isEmpty) {
      return <ProbeResult>[
        _skipped(
          'T10',
          'no other user has a verified attempt in this app session; save '
              'one as user A first, or type a UID and round ID',
        ),
      ];
    }
    if (uid == widget.deps.controller.uid) {
      return <ProbeResult>[
        _skipped('T10', 'that UID is the signed-in user; sign in as user B'),
      ];
    }
    return <ProbeResult>[
      await _probes.readForeign(uid, round),
      await _probes.writeForeign(uid),
    ];
  }

  Future<List<ProbeResult>> _runT11() async {
    final uid = widget.deps.controller.uid;
    if (uid == null) {
      return <ProbeResult>[_skipped('T11', 'no signed-in user')];
    }
    var round = _myRound.text.trim();
    if (round.isEmpty) {
      round = widget.deps.controller.lastVerifiedMine?.roundId ?? '';
    }
    if (round.isEmpty) {
      // Use this user's newest attempt on the server as the update target.
      final latest = await widget.deps.store.listFromServer(uid, limit: 1);
      if (latest.isNotEmpty) {
        round = latest.first.roundId;
      }
    }
    return <ProbeResult>[
      await _probes.createScoreEleven(uid),
      await _probes.createExtraField(uid),
      if (round.isNotEmpty)
        await _probes.updateExisting(uid, round)
      else
        _skipped('T11 update', 'this user has no saved attempt to update'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final deps = widget.deps;
    final faults = deps.faults;
    final controller = deps.controller;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Fault lab (development)')),
      body: SafeArea(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const StatusBanner(
              icon: Icons.science_outlined,
              color: kWarnColor,
              title: 'Development only',
              detail: 'Each fault fires once on the next request and is '
                  'labelled as injected wherever it appears.',
            ),
            const SizedBox(height: 8),
            Text(
              'Signed in as UID ${controller.shownId(controller.uid)}',
              style: text.bodyMedium,
            ),
            if (_running)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: StatusBanner(
                  icon: Icons.cloud_sync_outlined,
                  color: kInfoColor,
                  busy: true,
                  title: 'Sending probes to the deployed rules',
                ),
              ),
            if (_results.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('Probe results (newest first)', style: text.titleMedium),
            ],
            for (final result in _results)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: StatusBanner(
                  icon: result.passed ? Icons.gpp_good : Icons.gpp_bad,
                  color: result.passed ? kCorrectColor : kWrongColor,
                  title: '${result.passed ? 'DENIED' : 'NOT DENIED'}: '
                      '${result.label}',
                  detail: result.detail,
                ),
              ),
            if (faults != null)
              ListenableBuilder(
                listenable: faults,
                builder: (context, _) => _faultControls(context, faults),
              ),
            const Divider(height: 32),
            Text('Rule probes (deployed rules)', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(_otherTargetLine(), style: text.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _otherUid,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Other UID (optional override)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _otherRound,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Other round ID (optional override)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _running ? null : () => _run(_runT10),
              child: const Text('Run T10 probes'),
            ),
            const SizedBox(height: 16),
            Text(_myTargetLine(), style: text.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _myRound,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'My round ID (optional override)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _running ? null : () => _run(_runT11),
              child: const Text('Run T11 probes'),
            ),
            const Divider(height: 32),
            Text('Event log (newest first)', style: text.titleMedium),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: deps.log,
              builder: (context, _) {
                final lines = deps.log.lines.reversed.take(40).join('\n');
                return SelectableText(
                  lines.isEmpty ? 'No events yet.' : lines,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _otherTargetLine() {
    final other = widget.deps.controller.lastVerifiedOtherUser;
    if (other == null) {
      return 'T10 target: none yet. Save an attempt as user A, sign out, '
          'then sign in as user B in the same app session.';
    }
    return 'T10 target from this session: users/..${idSuffix(other.uid)}'
        '/attempts/..${idSuffix(other.roundId)}';
  }

  String _myTargetLine() {
    final mine = widget.deps.controller.lastVerifiedMine;
    if (mine == null) {
      return 'T11 update target: this user\'s newest attempt on the server.';
    }
    return 'T11 update target from this session: attempt '
        '..${idSuffix(mine.roundId)}';
  }

  Widget _faultControls(BuildContext context, FaultSwitches faults) {
    final text = Theme.of(context).textTheme;
    Widget chip(String label, bool selected, VoidCallback onSelected) {
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Divider(height: 32),
        Text('Next question request (T03)', style: text.titleMedium),
        Text('Armed: ${faults.question.name}'),
        Wrap(
          spacing: 8,
          children: <Widget>[
            chip(
              'No question fault',
              faults.question == QuestionFault.none,
              () => faults.armQuestion(QuestionFault.none),
            ),
            chip(
              'Inject bad JSON',
              faults.question == QuestionFault.badJson,
              () => faults.armQuestion(QuestionFault.badJson),
            ),
            chip(
              'Inject API code 1',
              faults.question == QuestionFault.apiCode,
              () => faults.armQuestion(QuestionFault.apiCode),
            ),
            chip(
              'Inject nine results',
              faults.question == QuestionFault.nineResults,
              () => faults.armQuestion(QuestionFault.nineResults),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Next score save (T09, T12)', style: text.titleMedium),
        Text('Armed: ${faults.save.name}'),
        Wrap(
          spacing: 8,
          children: <Widget>[
            chip(
              'No save fault',
              faults.save == SaveFault.none,
              () => faults.armSave(SaveFault.none),
            ),
            chip(
              'Inject lost acknowledgement',
              faults.save == SaveFault.dropAcknowledgement,
              () => faults.armSave(SaveFault.dropAcknowledgement),
            ),
            chip(
              'Inject unavailable',
              faults.save == SaveFault.unavailable,
              () => faults.armSave(SaveFault.unavailable),
            ),
            chip(
              'Inject resource-exhausted',
              faults.save == SaveFault.resourceExhausted,
              () => faults.armSave(SaveFault.resourceExhausted),
            ),
          ],
        ),
      ],
    );
  }
}
