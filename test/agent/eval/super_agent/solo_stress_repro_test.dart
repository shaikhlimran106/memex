import 'dart:io';

import 'package:dart_agent_core/eval.dart';
import 'package:flutter/widgets.dart';
import 'package:test/test.dart';

import 'environment.dart';
import 'harness.dart';
import 'tasks.dart';

/// Throwaway runner: runs ONLY the isolated compression-stress suite
/// (`_solo_stress`, a single ~16-turn task) so the long, expensive stress case
/// can be exercised without re-running the full capability suite. Not part of
/// the normal suite.
String? get _baseUrl {
  final v = Platform.environment['SHARK_OPENAI_BASE_URL'] ??
      Platform.environment['OPENAI_BASE_URL'] ??
      '';
  return v.isEmpty ? null : v;
}

String? get _apiKey {
  final v = Platform.environment['SHARK_OPENAI_API_KEY'] ??
      Platform.environment['OPENAI_API_KEY'] ??
      '';
  return v.isEmpty ? null : v;
}

bool get _hasLiveEnv => _baseUrl != null && _apiKey != null;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  late SuperAgentEvalRuntime runtime;

  setUpAll(() async {
    if (!_hasLiveEnv) return;
    runtime = await SuperAgentEvalRuntime.setUp(
      baseUrl: _baseUrl!,
      apiKey: _apiKey!,
      modelId: Platform.environment['EVAL_MODEL'] ?? 'memex-default',
    );
  });

  tearDownAll(() async {
    if (!_hasLiveEnv) return;
    await runtime.tearDown();
  });

  test(
    'solo compression-stress suite',
    () async {
      final suiteDir =
          Directory('test/agent/eval/super_agent/suites/_solo_stress');
      final suite = buildSuperAgentSuite(suiteDir: suiteDir.path);

      final runner = EvalRunner(
        environment: SuperAgentEvalEnvironment(suiteDir: suiteDir),
        harnessFactory: const SuperAgentHarnessFactory(),
        exporters: const [],
        reportStore:
            FileReportStore(Directory('.state_dir/.eval_reports_stress')),
      );

      final report = await runner.runSuite(
        runName: 'solo_stress_${DateTime.now().millisecondsSinceEpoch}',
        suite: suite,
        concurrency: 1,
      );
      // ignore: avoid_print
      print(report.toMarkdownSummary());
    },
    skip: _hasLiveEnv ? false : 'no live env',
    timeout: const Timeout(Duration(minutes: 40)),
    tags: const ['live'],
  );
}
