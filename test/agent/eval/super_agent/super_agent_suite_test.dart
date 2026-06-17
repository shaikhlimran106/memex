import 'dart:io';

import 'package:dart_agent_core/eval.dart';
import 'package:flutter/widgets.dart';
import 'package:test/test.dart';

import 'environment.dart';
import 'harness.dart';
import 'tasks.dart';

/// SuperAgent capability eval. Loads `suites/capability/` via the framework's
/// `loadEvalSuiteFromDir`, drives the production `SuperAgent.createAgent` +
/// `agent.run` chat codepath end-to-end (the same entry `ChatService` uses),
/// and scores each trial with the registered deterministic CODE graders.
///
/// There is NO LLM-as-judge inside the run. The qualitative dimensions
/// (capture faithfulness, title quality, PKM grounding, reply helpfulness,
/// dynamic-card visual sense) are scored AFTER the run by reading the per-trial
/// judgment packages the harness writes to `.state_dir/.eval_judgment/`.
///
/// `EVAL_MODEL` selects the model under test (default: sonnet-4.6, the
/// production model). Credentials come from SHARK_* env vars:
///
///     export SHARK_OPENAI_BASE_URL='https://.../v1'
///     export SHARK_OPENAI_API_KEY='sk-...'
///     export EVAL_MODEL='anthropic/claude-sonnet-4.6'   # optional override
///     flutter test test/agent/eval/super_agent/super_agent_suite_test.dart -r expanded
///
/// Reports land in `.state_dir/.eval_reports/`, traces in
/// `.state_dir/.eval_traces/`, judgment packages in `.state_dir/.eval_judgment/`
/// (all under the gitignored `.state_dir/`).
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
      modelId:
          Platform.environment['EVAL_MODEL'] ?? 'anthropic/claude-sonnet-4.6',
    );
  });

  tearDownAll(() async {
    if (!_hasLiveEnv) return;
    await runtime.tearDown();
  });

  test(
    'super_agent_capability suite',
    () async {
      final tracesDir = Directory('.state_dir/.eval_traces')
        ..createSync(recursive: true);
      final reportsDir = Directory('.state_dir/.eval_reports')
        ..createSync(recursive: true);
      final tracesFile = File(
        '${tracesDir.path}/super_agent_${DateTime.now().millisecondsSinceEpoch}.jsonl',
      );

      final suiteDir = Directory(defaultSuperAgentSuiteDir());
      final suite = buildSuperAgentSuite(suiteDir: suiteDir.path);

      final runner = EvalRunner(
        environment: SuperAgentEvalEnvironment(
          suiteDir: suiteDir,
        ),
        harnessFactory: const SuperAgentHarnessFactory(),
        exporters: [JsonlTraceExporter(tracesFile)],
        reportStore: FileReportStore(reportsDir),
      );

      final report = await runner.runSuite(
        runName: 'super_agent_${DateTime.now().millisecondsSinceEpoch}',
        suite: suite,
        concurrency: 4,
      );

      // ignore: avoid_print
      print(report.toMarkdownSummary());

      expect(report.trials, isNotEmpty);
      final allErrored =
          report.trials.every((r) => r.trial.status == TrialStatus.errored);
      expect(allErrored, isFalse,
          reason: 'every trial errored — likely a setup / harness bug, '
              'not an agent quality issue');
    },
    skip: _hasLiveEnv
        ? false
        : 'SHARK_OPENAI_BASE_URL / SHARK_OPENAI_API_KEY not set — skipping live eval',
    timeout: const Timeout(Duration(minutes: 45)),
    tags: const ['live'],
  );
}
