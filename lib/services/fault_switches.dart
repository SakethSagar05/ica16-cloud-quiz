import 'package:flutter/foundation.dart';

/// Development-only faults for the question request (test T03).
enum QuestionFault { none, badJson, apiCode, nineResults }

/// Development-only faults for the score save (tests T09 and T12).
enum SaveFault { none, dropAcknowledgement, unavailable, resourceExhausted }

/// Holds the fault that is armed for the next request. Each fault fires once
/// and then disarms itself, so the retry that follows is a real request.
/// This object only exists when the fault lab is compiled in.
class FaultSwitches extends ChangeNotifier {
  QuestionFault _question = QuestionFault.none;
  SaveFault _save = SaveFault.none;

  QuestionFault get question => _question;
  SaveFault get save => _save;

  void armQuestion(QuestionFault fault) {
    _question = fault;
    notifyListeners();
  }

  void armSave(SaveFault fault) {
    _save = fault;
    notifyListeners();
  }

  QuestionFault takeQuestionFault() {
    final fault = _question;
    if (fault != QuestionFault.none) {
      _question = QuestionFault.none;
      notifyListeners();
    }
    return fault;
  }

  SaveFault takeSaveFault() {
    final fault = _save;
    if (fault != SaveFault.none) {
      _save = SaveFault.none;
      notifyListeners();
    }
    return fault;
  }
}
