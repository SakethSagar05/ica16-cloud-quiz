import 'package:flutter/foundation.dart';

/// In-memory trace of what the app did, newest last.
///
/// Every line is also printed to the device log with an `[ICA16]` prefix so a
/// test run can be matched to its screenshots. Callers pass ID suffixes only:
/// emails, passwords and tokens never reach this log.
class EventLog extends ChangeNotifier {
  static const int _maxLines = 300;

  final List<String> _lines = <String>[];

  List<String> get lines => List<String>.unmodifiable(_lines);

  void add(String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} $message';
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
    debugPrint('[ICA16] $line');
    notifyListeners();
  }
}

/// Last six characters of an ID, used in logs and on screen so evidence can be
/// correlated without publishing the full identifier.
String idSuffix(String? id) {
  if (id == null || id.isEmpty) {
    return '-';
  }
  return id.length <= 6 ? id : id.substring(id.length - 6);
}

/// UTC time in ISO 8601, or a placeholder when the server has not set it.
String formatStamp(DateTime? time) {
  if (time == null) {
    return 'not resolved';
  }
  return time.toUtc().toIso8601String();
}
