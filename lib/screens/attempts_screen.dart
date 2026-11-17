import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/attempt.dart';
import '../services/attempt_store.dart';
import '../util/event_log.dart';
import '../widgets/common.dart';

/// The signed-in user's attempts, read from the server only. This is how a
/// saved attempt is retrieved after an app restart without playing again.
class AttemptsScreen extends StatefulWidget {
  const AttemptsScreen({super.key, required this.deps, required this.uid});

  final AppDeps deps;
  final String uid;

  @override
  State<AttemptsScreen> createState() => _AttemptsScreenState();
}

class _AttemptsScreenState extends State<AttemptsScreen> {
  static const Duration _timeout = Duration(seconds: 15);

  final TextEditingController _lookup = TextEditingController();
  List<ServerAttempt>? _attempts;
  ServerAttempt? _opened;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _lookup.dispose();
    super.dispose();
  }

  String _explain(Object error) {
    if (error is StoreException) {
      return 'The server read failed (${error.code}). '
          'Nothing is shown from the cache.';
    }
    if (error is TimeoutException) {
      return 'The server did not answer within 15 seconds. '
          'Nothing is shown from the cache.';
    }
    return 'The server read failed.';
  }

  Future<void> _refresh() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await widget.deps.store
          .listFromServer(widget.uid)
          .timeout(_timeout);
      widget.deps.log.add(
        'uid=..${idSuffix(widget.uid)} listed ${list.length} attempts '
        'from the server',
      );
      if (!mounted) {
        return;
      }
      setState(() => _attempts = list);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = _explain(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _open(String roundId) async {
    final id = roundId.trim();
    if (id.isEmpty || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _opened = null;
    });
    try {
      final found = await widget.deps.store
          .readFromServer(widget.uid, id)
          .timeout(_timeout);
      widget.deps.log.add(
        'uid=..${idSuffix(widget.uid)} round=..${idSuffix(id)} server read: '
        '${found == null ? 'not found' : 'found correctCount=${found.correctCount} submittedAt=${formatStamp(found.submittedAt)} fromCache=${found.fromCache}'}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _opened = found;
        if (found == null) {
          _error = 'The server has no attempt with that round ID for this '
              'account.';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = _explain(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.deps.controller;
    final text = Theme.of(context).textTheme;
    final attempts = _attempts;
    final opened = _opened;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud attempts')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Read from the server for UID ${controller.shownId(widget.uid)}',
              style: text.titleMedium,
            ),
            const SizedBox(height: 12),
            if (_busy)
              const StatusBanner(
                icon: Icons.cloud_sync_outlined,
                color: kInfoColor,
                busy: true,
                title: 'Reading from the server',
              ),
            if (error != null)
              StatusBanner(
                icon: Icons.cloud_off,
                color: kWrongColor,
                title: 'Not available',
                detail: error,
              ),
            if (opened != null) ...<Widget>[
              const StatusBanner(
                icon: Icons.cloud_done,
                color: kCorrectColor,
                title: 'Attempt retrieved from the server',
              ),
              const SizedBox(height: 8),
              AttemptCard(attempt: opened, controller: controller),
            ],
            const SizedBox(height: 16),
            if (attempts != null) ...<Widget>[
              Text(
                '${attempts.length} saved '
                '${attempts.length == 1 ? 'attempt' : 'attempts'} '
                '(newest first, up to 20)',
                style: text.titleSmall,
              ),
              for (final attempt in attempts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(
                    'Attempt ${controller.shownId(attempt.roundId)}: '
                    '${attempt.correctCount ?? '?'} / 10',
                  ),
                  subtitle: Text(formatStamp(attempt.submittedAt)),
                  onTap: () => _open(attempt.roundId),
                ),
            ],
            const Divider(height: 32),
            TextField(
              controller: _lookup,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Round ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _open(_lookup.text),
              child: const Text('Look up on server'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _refresh,
              child: const Text('Refresh list'),
            ),
          ],
        ),
      ),
    );
  }
}
