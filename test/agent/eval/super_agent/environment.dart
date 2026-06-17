import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:logging/logging.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Process-wide initialization for the SuperAgent eval. `FileSystemService` /
/// `SharedPreferences` are app-singletons, so we initialize them **once** for
/// the whole run and let each trial scope itself by `userId`. Mirrors
/// `PkmAgentEvalRuntime` / `CardAgentEvalRuntime`.
///
/// NOTE: this suite has NO LLM-as-judge wired into the run. The qualitative
/// dimensions (capture faithfulness, title quality, PKM grounding, reply
/// helpfulness, dynamic-card visual sense) are scored AFTER the run by reading
/// the per-trial judgment packages the harness writes to
/// `.state_dir/.eval_judgment/`. The code graders here only assert the
/// deterministic invariants.
class SuperAgentEvalRuntime {
  final Directory dataRoot;

  SuperAgentEvalRuntime._(this.dataRoot);

  static Future<SuperAgentEvalRuntime> setUp({
    required String baseUrl,
    required String apiKey,
    required String modelId,
  }) async {
    _setupConsoleLogging();

    SharedPreferences.setMockInitialValues({});
    await UserStorage.initL10n();
    await UserStorage.saveLLMConfigs([
      LLMConfig(
        key: LLMConfig.defaultClientKey,
        type: LLMConfig.typeChatCompletion,
        modelId: modelId,
        apiKey: apiKey,
        baseUrl: baseUrl,
        maxTokens: 8192,
        extra: const {},
      ),
    ]);
    AgentActivityService.setInstance(LocalAgentActivityService.instance);

    final dataRoot =
        await Directory.systemTemp.createTemp('memex_super_eval_root_');
    await FileSystemService.init(dataRoot.path);

    return SuperAgentEvalRuntime._(dataRoot);
  }

  Future<void> tearDown() async {
    if (await dataRoot.exists()) {
      await dataRoot.delete(recursive: true);
    }
  }

  static bool _loggingSet = false;
  static void _setupConsoleLogging() {
    if (_loggingSet) return;
    _loggingSet = true;
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) {
      // ignore: avoid_print
      print('[${r.level.name}] ${r.loggerName}: ${r.message}');
      if (r.error != null) {
        // ignore: avoid_print
        print('  error: ${r.error}');
      }
    });
  }
}

/// Per-trial environment. Assumes [SuperAgentEvalRuntime.setUp] ran once before
/// `runSuite`. `prepare`/`dispose` only touch this trial's own resources (a
/// unique `userId`, a fresh controller) — no global singletons are swapped.
class SuperAgentEvalEnvironment implements EvalEnvironment {
  final Directory suiteDir;

  SuperAgentEvalEnvironment({required this.suiteDir});

  @override
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
    final userId =
        '${trial.taskId}_${trial.trialIndex}_${DateTime.now().microsecondsSinceEpoch}';
    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.chatAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );
    return EvalContext(
      workspaceDir: Directory(
        FileSystemService.instance.getWorkspacePath(userId),
      ),
      clock: const SystemEvalClock(),
      llmClient: resources.client,
      controller: AgentController(),
      servicesMap: {
        ModelConfig: resources.modelConfig,
      },
      metadata: {
        'user_id': userId,
        'suite_dir': suiteDir.path,
        'task_input_content': task.input['content'] as String? ?? '',
      },
    );
  }

  @override
  Future<void> dispose(EvalContext ctx) async {
    final dir = ctx.workspaceDir;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
    ctx.controller.close();
  }
}
