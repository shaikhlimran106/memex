import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';

class DelegateProgress {
  const DelegateProgress({
    required this.delegateRunId,
    required this.childName,
    required this.taskBrief,
  });

  final String delegateRunId;
  final String childName;
  final String taskBrief;
}

abstract class DelegateProgressSink {
  void delegateStarted(DelegateProgress progress);

  void childToolStarted({
    required DelegateProgress progress,
    required String toolName,
    required String arguments,
  });

  void childToolFinished({
    required DelegateProgress progress,
    required FunctionExecutionResult result,
  });

  void delegateFinished({
    required DelegateProgress progress,
    required String status,
    required String summary,
  });
}

class DelegateProgressContext {
  DelegateProgressContext._();

  static final Object _zoneKey = Object();

  static DelegateProgressSink? get current =>
      Zone.current[_zoneKey] as DelegateProgressSink?;

  static R run<R>(DelegateProgressSink sink, R Function() body) {
    return runZoned(body, zoneValues: {_zoneKey: sink});
  }
}
