import 'dart:io';

import 'package:dart_agent_core/eval.dart';
import 'package:memex/agent/pkm_agent/pkm_agent.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/time_context.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;

/// PKM Agent harness factory. One session per trial; each session
/// 1. copies the task's `fixture_dir` into the per-user workspace
/// 2. runs the production `PkmAgent.runWithContent` codepath
/// 3. snapshots the final PKM state and workspace diff for outcome graders.
/// Generic execution trajectory (messages, tool calls, token metrics) is
/// recorded by dart_agent_core's eval runner through [EvalContext.controller].
class PkmAgentHarnessFactory implements AgentHarnessFactory {
  const PkmAgentHarnessFactory();

  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async =>
      _PkmAgentSession(task: task, trial: trial, ctx: context);
}

class _PkmAgentSession implements AgentHarnessSession {
  final EvalTask task;
  final Trial trial;
  final EvalContext ctx;

  _PkmAgentSession({
    required this.task,
    required this.trial,
    required this.ctx,
  });

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final userId = ctx.metadata['user_id'] as String;
    final suiteDir = ctx.metadata['suite_dir'] as String;
    final fs = FileSystemService.instance;

    // 1. Seed the per-user workspace. Two layers (base then overlay) so
    //    most tasks can share the realistic "starter" PKM and only
    //    declare the deltas that matter for their case.
    final destWorkspace = Directory(fs.getWorkspacePath(userId));
    final baseFixture = task.input['base_fixture'] as String?;
    if (baseFixture != null && baseFixture.isNotEmpty) {
      final baseDir = Directory(p.join(suiteDir, baseFixture));
      if (!baseDir.existsSync()) {
        throw StateError(
          'base_fixture does not exist on disk: ${baseDir.path}',
        );
      }
      await _copyDirectory(baseDir, destWorkspace);
    }

    final fixtureRel = task.input['fixture_dir'] as String?;
    if (fixtureRel == null || fixtureRel.isEmpty) {
      throw StateError('task ${task.id} missing required input.fixture_dir');
    }
    final fixtureDir = Directory(p.join(suiteDir, fixtureRel));
    if (!fixtureDir.existsSync()) {
      throw StateError(
        'fixture_dir does not exist on disk: ${fixtureDir.path}',
      );
    }
    await _copyDirectory(fixtureDir, destWorkspace);

    final factId = task.input['fact_id'] as String;
    final content = task.input['content'] as String;
    final pkmRoot = Directory(fs.getPkmPath(userId));
    final beforePkmSnapshot = await _snapshotPkm(pkmRoot);

    // 2. Build the same instruction prompt the production handler uses,
    //    then run the agent. We bypass `processWithPkmAgent` because it
    //    swallows the completion evidence; we need that for graders.
    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.pkmAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );
    final instruction = Prompts.pkmAgentInstructionForNewPublishedContent(
      formatLocalDateTimeWithZone(DateTime.now()),
      factId,
      content,
      '', // no asset info for eval tasks
    );

    PkmRunCompletionEvidence evidence;
    try {
      evidence = await PkmAgent.runWithContent(
        client: resources.client,
        modelConfig: resources.modelConfig,
        userId: userId,
        factId: factId,
        instruction: instruction,
        controller: ctx.controller,
      );
    } catch (_) {
      // If the production retry loop gives up, inspect the workspace
      // anyway so graders can see partial progress.
      evidence = const PkmRunCompletionEvidence(
        wrotePara: false,
        updatedInsight: false,
        skippedPkm: false,
        successfulPkmMutation: false,
      );
    }

    // 3. Snapshot final PKM file contents (relative paths under PKM/) and
    //    compute an outcome-level workspace diff. Tool ordering and payloads
    //    belong to the transcript and are recorded by the framework.
    final afterPkmSnapshot = await _snapshotPkm(pkmRoot);
    final workspaceDiff = _diffSnapshots(beforePkmSnapshot, afterPkmSnapshot);

    return (
      transcript: Transcript(
        messages: const [],
        toolCalls: const [],
        metrics: const TranscriptMetrics(
          nTurns: 0,
          nToolCalls: 0,
          nTotalTokens: 0,
        ),
      ),
      outcome: Outcome(environmentState: {
        'is_complete': evidence.isComplete,
        'wrote_para': evidence.wrotePara,
        'updated_insight': evidence.updatedInsight,
        'skipped_pkm': evidence.skippedPkm,
        'successful_pkm_mutation': evidence.successfulPkmMutation,
        'missing_requirements': evidence.missingRequirements,
        'skip_evidence': evidence.skipEvidence,
        'file_contents': afterPkmSnapshot,
      }, workspaceDiff: workspaceDiff),
    );
  }

  @override
  Future<void> dispose() async {}
}

Future<Map<String, String>> _snapshotPkm(Directory pkmRoot) async {
  final fileContents = <String, String>{};
  if (!await pkmRoot.exists()) return fileContents;
  await for (final entry in pkmRoot.list(recursive: true)) {
    if (entry is! File) continue;
    final rel = p.relative(entry.path, from: pkmRoot.path);
    fileContents[rel] = await entry.readAsString();
  }
  return fileContents;
}

WorkspaceDiff _diffSnapshots(
  Map<String, String> before,
  Map<String, String> after,
) {
  final created = <String>[];
  final modified = <String>[];
  final deleted = <String>[];
  final snippets = <String, String>{};

  for (final entry in after.entries) {
    final old = before[entry.key];
    if (old == null) {
      created.add(entry.key);
      snippets[entry.key] = _snippet(entry.value);
    } else if (old != entry.value) {
      modified.add(entry.key);
      snippets[entry.key] = _snippet(entry.value);
    }
  }
  for (final path in before.keys) {
    if (!after.containsKey(path)) deleted.add(path);
  }

  created.sort();
  modified.sort();
  deleted.sort();
  return WorkspaceDiff(
    created: created,
    modified: modified,
    deleted: deleted,
    contentSnippets: snippets,
  );
}

String _snippet(String content) {
  const maxChars = 4096;
  if (content.length <= maxChars) return content;
  return content.substring(0, maxChars);
}

/// Recursive `cp -R` for fixture seeding.
Future<void> _copyDirectory(Directory src, Directory dst) async {
  if (!await src.exists()) return;
  await dst.create(recursive: true);
  await for (final entry in src.list(recursive: false)) {
    final name = p.basename(entry.path);
    if (entry is Directory) {
      await _copyDirectory(entry, Directory(p.join(dst.path, name)));
    } else if (entry is File) {
      await entry.copy(p.join(dst.path, name));
    }
  }
}
