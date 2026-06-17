import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/agent/built_in_tools/file_tools.dart';
import 'package:memex/agent/common_tools.dart';
import 'package:memex/agent/security/file_permission_manager.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/agent/super_agent/super_agent_harness.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/time_context.dart';

final _logger = getLogger('SuperAgentChild');

/// Which base (non-skill) tools a child worker gets, on top of the tools that
/// come from its activated skills. Avoids re-listing tool sets at every call
/// site — the fan-out caller just names a profile.
enum ChildToolProfile {
  /// Only the child's skill tools (+ skill activate/deactivate). No base file
  /// tools at all.
  none,

  /// Skill tools + all read-only base tools (LS / Glob / Grep / Read /
  /// BatchRead / view_image / getCurrentTime / get_pkm_overview).
  read,

  /// `read` + the generic write tools (Write / Edit / MOVE / Remove). Writes
  /// are still bounded by the permission manager's [writeRootPaths].
  full,
}

/// One bounded child-worker run configuration. A child is a temporary worker
/// SuperAgent spawns within a single turn: its own [AgentState], a narrow base
/// prompt, one or more force-activated skills, a scoped tool profile, and a
/// hard write-path allow-list. It never persists across turns and never talks
/// to the user.
class SuperAgentChildConfig {
  /// Short label for logging / UI (e.g. `card_child`). Not a business type.
  final String childName;

  /// The task instruction for this child run.
  final String taskBrief;

  /// Read-only context the runtime hands the child: fact_id, captured-at time,
  /// location reminder, existing card / schedule snapshots, asset analyses,
  /// etc. Rendered deterministically into the child's first message so the
  /// child never has to infer record identity or timing.
  final Map<String, dynamic> contextPacket;

  /// Skills available to this child. The caller pre-sets `forceActivate` on the
  /// ones that should be always-on (e.g. the card skill for the card child).
  /// Non-force skills here can be self-activated by the child on demand (e.g.
  /// the card child activating `dynamic_timeline_ui` when no built-in template
  /// fits). Passing built instances (rather than names) keeps this type-safe
  /// and avoids a brittle name→skill registry.
  final List<Skill> skills;

  /// Base tool profile (see [ChildToolProfile]).
  final ChildToolProfile toolProfile;

  /// Absolute workspace-relative roots this child may WRITE to (e.g.
  /// `/Cards`, `/PKM`, `/_UserSettings/Templates`). Everything else is
  /// read-only; `Facts` / `_System` stay locked by the default rules. Enforced
  /// by [FilePermissionManager], not by prompt text.
  final List<String> writeRootPaths;

  /// Hard wall-clock bound for this child's run.
  final Duration timeout;

  const SuperAgentChildConfig({
    required this.childName,
    required this.taskBrief,
    required this.skills,
    this.contextPacket = const {},
    this.toolProfile = ChildToolProfile.read,
    this.writeRootPaths = const [],
    this.timeout = const Duration(minutes: 4),
  });
}

/// Terminal status of a child run. `no_op` is a first-class, non-failure
/// result (e.g. a record that doesn't warrant PKM organization).
enum SuperAgentChildStatus { completed, noOp, failed, needsParentInput }

SuperAgentChildStatus _statusFromWire(String? v) {
  switch (v) {
    case 'completed':
      return SuperAgentChildStatus.completed;
    case 'no_op':
      return SuperAgentChildStatus.noOp;
    case 'needs_parent_input':
      return SuperAgentChildStatus.needsParentInput;
    case 'failed':
    default:
      return SuperAgentChildStatus.failed;
  }
}

/// Structured outcome the parent runtime collects from a child run.
class SuperAgentChildResult {
  final String childName;
  final SuperAgentChildStatus status;

  /// The child's final natural-language text (its self-report).
  final String summary;

  /// Best-effort structured payload parsed from the child's final message
  /// (the child is asked to end with a JSON object). Empty when the child
  /// returned plain prose or nothing parseable.
  final Map<String, dynamic> structured;

  /// Set when the run threw / timed out before the child could report.
  final String? error;

  const SuperAgentChildResult({
    required this.childName,
    required this.status,
    required this.summary,
    this.structured = const {},
    this.error,
  });

  factory SuperAgentChildResult.failed(String childName, String error) =>
      SuperAgentChildResult(
        childName: childName,
        status: SuperAgentChildStatus.failed,
        summary: error,
        error: error,
      );

  Map<String, dynamic> toJson() => {
        'child': childName,
        'status': status.name,
        'summary': summary,
        if (structured.isNotEmpty) 'structured': structured,
        if (error != null) 'error': error,
      };
}

/// Base system prompt shared by every child worker. Skill-specific instructions
/// arrive via the force-activated skills; this only frames the worker contract.
String buildChildBasePrompt() {
  return '''
# Memex Subagent Worker

You are a temporary worker spawned by the Memex SuperAgent for ONE bounded task.
You are NOT the user-facing SuperAgent. Do not chat with the user, do not ask
the user questions, and do not produce user-facing chit-chat. Your final
message is parsed by the parent runtime.

## Scope
- Work only on the task brief and context packet provided in this run.
- Follow the active skill instructions for this run.
- Use ONLY the fact_id, timestamps, assets, and context explicitly provided.
  Never invent or guess record identity.
- You CANNOT see the user's attachments. The brief describes what each
  attachment contains and gives its reference — rely on that description as the
  attachment's content, and use the references exactly as given.
- Do not perform side effects outside your assigned write scope.
- Do not write long-term memory. Do not spawn other agents.

## Truthfulness
- Report tool failures truthfully. Never claim a change succeeded unless the
  tool result proves it. Do not invent reasons for a failure.
- If your branch does not apply to this record, that is normal — return a
  `no_op` result with a short reason. Do not force a write just to look busy.
- If you genuinely cannot proceed without information the parent did not
  provide, return `needs_parent_input` naming the exact missing field.

## Output
End your run with a concise plain-text summary, then a single fenced JSON object
on its own describing the structured result, e.g.:

```json
{"status": "completed | no_op | failed | needs_parent_input", "summary": "..."}
```

Include any branch-specific fields your skill instructions ask for (such as
`fact_id`, `card_changed`, `pkm_changed`, `schedule_changed`, `changed_files`).
''';
}

/// Renders the runtime-provided context packet into a single `<system-reminder>`
/// block, mirroring how `ChatService` assembles per-turn context. Time and
/// location are passed deterministically (not left to the parent to remember to
/// put in the brief) because a missing capture time would corrupt event /
/// schedule reasoning.
String _buildContextReminder(Map<String, dynamic> packet) {
  final sections = <String>[];

  final factId = packet['fact_id'];
  if (factId is String && factId.isNotEmpty) {
    sections.add('Record fact_id: $factId (use this exact id; never invent one)');
  }

  final capturedAt = packet['captured_at'];
  if (capturedAt is DateTime) {
    sections.add('User Message Time: ${formatLocalDateTimeWithZone(capturedAt)}');
  } else if (capturedAt is String && capturedAt.isNotEmpty) {
    sections.add('User Message Time: $capturedAt');
  }
  sections.add('Current Local Time: ${formatLocalDateTimeWithZone(DateTime.now())}');

  final location = packet['location_reminder'];
  if (location is String && location.trim().isNotEmpty) {
    sections.add(location.trim());
  }

  return '<system-reminder>\n${sections.join('\n\n')}\n</system-reminder>';
}

/// Assemble the base tool set for a [ChildToolProfile]. Skill tools are added
/// by the agent itself from the (force-)active skills, so they are NOT listed
/// here — this only covers the generic base tools.
List<Tool> _baseToolsForProfile(
  ChildToolProfile profile,
  FileToolFactory factory,
) {
  switch (profile) {
    case ChildToolProfile.none:
      return const [];
    case ChildToolProfile.read:
      return [
        factory.buildLSTool(),
        factory.buildGlobTool(),
        factory.buildGrepTool(),
        factory.buildReadTool(),
        factory.buildBatchReadTool(),
        factory.buildViewImageTool(),
        getCurrentTimeTool,
        getPkmOverviewTool,
      ];
    case ChildToolProfile.full:
      return [
        factory.buildLSTool(),
        factory.buildGlobTool(),
        factory.buildGrepTool(),
        factory.buildReadTool(),
        factory.buildBatchReadTool(),
        factory.buildViewImageTool(),
        factory.buildWriteTool(),
        factory.buildEditTool(),
        factory.buildMoveTool(),
        factory.buildRemoveTool(),
        getCurrentTimeTool,
        getPkmOverviewTool,
      ];
  }
}

/// Builds a child worker [StatefulAgent] with its own fresh state, scoped
/// permissions, base prompt + skills, and tool profile. Does NOT run it — see
/// [runSuperAgentChild].
StatefulAgent createSuperAgentChild({
  required SuperAgentChildConfig config,
  required LLMClient client,
  required ModelConfig modelConfig,
  required String userId,
}) {
  final fileService = FileSystemService.instance;
  final workingDirectory = fileService.getWorkspacePath(userId);

  // Map the write-path allow-list to write rules; default rules keep the rest
  // of the workspace read-only and Facts/_System locked.
  final writeRules = <PermissionRule>[
    for (final root in config.writeRootPaths)
      PermissionRule(
        rootPath: _resolveWorkspacePath(fileService, userId, root),
        access: FileAccessType.write,
      ),
  ];
  final permissionManager =
      FilePermissionManager(userId, writeRules);

  final fileToolFactory = FileToolFactory(
    permissionManager: permissionManager,
    workingDirectory: workingDirectory,
  );

  final tools = _baseToolsForProfile(config.toolProfile, fileToolFactory);

  // dynamic_timeline_ui designs HTML templates by editing files under the
  // template dir. Rather than granting the whole worker generic write tools
  // (a `full` profile, which becomes a misuse magnet elsewhere), inject the
  // scoped file tools INTO the skill so they only appear while the worker is
  // actually designing a template. The tools are bounded by this child's
  // permission manager (its writeRootPaths). Skills arrive pre-built in the
  // config, so we rebuild the dynamic-UI skill here where the FileToolFactory
  // (and thus userId-scoped permissions) finally exists.
  final skills = config.skills.map((skill) {
    if (skill is DynamicTimelineUiSkill) {
      return DynamicTimelineUiSkill(
        forceActivate: skill.forceActivate,
        extraTools: [
          fileToolFactory.buildReadTool(),
          fileToolFactory.buildWriteTool(),
          fileToolFactory.buildEditTool(),
          fileToolFactory.buildLSTool(),
          fileToolFactory.buildGlobTool(),
          fileToolFactory.buildGrepTool(),
        ],
      );
    }
    return skill;
  }).toList();

  final state = AgentState(
    sessionId:
        '${config.childName}_${DateTime.now().microsecondsSinceEpoch}',
    metadata: {
      'userId': userId,
      'sub_agent_mode': true,
      'child_name': config.childName,
    },
  );

  return StatefulAgent(
    name: config.childName,
    client: client,
    modelConfig: modelConfig,
    state: state,
    tools: tools,
    skills: skills,
    systemPrompts: [buildChildBasePrompt()],
    disableSubAgents: true,
    withGeneralPrinciples: true,
    planMode: PlanMode.none,
    // PKM organization now happens inside these workers, so the PKM
    // structural-health reminders ride along here (only fire on /PKM reads).
    postToolCallHook: SuperAgentHarness.buildChildPostToolCallHook(userId),
  );
}

/// Maps a workspace-relative root like `/Cards` to an absolute path; passes an
/// already-absolute path through unchanged.
String _resolveWorkspacePath(
  FileSystemService fileService,
  String userId,
  String root,
) {
  final workspace = fileService.getWorkspacePath(userId);
  if (root.startsWith(workspace)) return root;
  final rel = root.startsWith('/') ? root.substring(1) : root;
  return rel.isEmpty ? workspace : '$workspace/$rel';
}

/// Builds and runs a child worker to completion (or timeout), then extracts a
/// [SuperAgentChildResult] from its final message. Never throws — a thrown /
/// timed-out run becomes a `failed` result so the parent can still merge.
Future<SuperAgentChildResult> runSuperAgentChild({
  required SuperAgentChildConfig config,
  required LLMClient client,
  required ModelConfig modelConfig,
  required String userId,
}) async {
  try {
    final agent = createSuperAgentChild(
      config: config,
      client: client,
      modelConfig: modelConfig,
      userId: userId,
    );

    final reminder = _buildContextReminder(config.contextPacket);
    final initial = UserMessage([
      TextPart(reminder),
      TextPart(config.taskBrief),
    ]);

    final messages = await agent
        .run([initial], useStream: false)
        .timeout(config.timeout);

    final finalText = _lastText(messages);
    final structured = _extractJson(finalText);
    final status = _statusFromWire(structured['status'] as String?);

    _logger.info(
        'Child ${config.childName} finished: status=${status.name}');

    return SuperAgentChildResult(
      childName: config.childName,
      status: status,
      summary: (structured['summary'] as String?) ?? finalText,
      structured: structured,
    );
  } on TimeoutException {
    _logger.warning('Child ${config.childName} timed out');
    return SuperAgentChildResult.failed(
        config.childName, 'child timed out after ${config.timeout.inSeconds}s');
  } catch (e, st) {
    _logger.severe('Child ${config.childName} errored', e, st);
    return SuperAgentChildResult.failed(config.childName, e.toString());
  }
}

String _lastText(List<LLMMessage> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m is ModelMessage && (m.textOutput?.trim().isNotEmpty ?? false)) {
      return m.textOutput!.trim();
    }
  }
  return '';
}

/// Pull the first {...} JSON object out of [text]. Tolerant of markdown fences
/// and surrounding prose. Returns an empty map when nothing parses.
Map<String, dynamic> _extractJson(String text) {
  if (text.isEmpty) return const {};
  var s = text;
  final fence = text.indexOf('```');
  if (fence >= 0) {
    final after = text.substring(fence + 3);
    final lf = after.indexOf('\n');
    final body = lf >= 0 ? after.substring(lf + 1) : after;
    final end = body.indexOf('```');
    s = end >= 0 ? body.substring(0, end) : body;
  }
  final lo = s.indexOf('{');
  final hi = s.lastIndexOf('}');
  if (lo < 0 || hi <= lo) return const {};
  try {
    final decoded = jsonDecode(s.substring(lo, hi + 1));
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}
