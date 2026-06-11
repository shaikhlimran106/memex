import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:memex/agent/agent_system_prompt_helper.dart';
import 'package:memex/agent/agent_controller.util.dart';
import 'package:memex/agent/built_in_tools/file_tools.dart';
import 'package:memex/agent/built_in_tools/search_event_logs_tool.dart';
import 'package:memex/agent/memory/memory_management.dart';
import 'package:memex/agent/memory/super_agent_context_compressor.dart';
import 'package:memex/agent/skills/manage_pkm/pkm_skill.dart';
import 'package:memex/agent/security/file_permission_manager.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/agent/skills/manage_timeline_card/timeline_card_skill.dart';
import 'package:memex/agent/skills/manage_system_action/system_action_skill.dart';
import 'package:memex/agent/skills/knowledge_insight/knowledge_insight_skill.dart';
import 'package:memex/agent/skills/ask_clarification/ask_clarification_skill.dart';
import 'package:memex/agent/skills/submit_record/submit_record_skill.dart';
import 'package:memex/agent/skills/timeline_diagnostics/timeline_diagnostics_skill.dart';
import 'package:memex/agent/common_tools.dart';
import 'package:memex/agent/state_util.dart';
import 'package:memex/agent/super_agent/prompts.dart';
import 'package:memex/agent/super_agent/pending_tool_image_buffer.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:logging/logging.dart';
import 'package:memex/utils/logger.dart';

/// Read-only tool names available in Quick Query mode.
const _readOnlyToolNames = {
  'LS',
  'Glob',
  'Grep',
  'Read',
  'BatchRead',
  'search_event_logs',
  'getCurrentTime',
  'get_pkm_overview',
};

/// Skills excluded in Quick Query mode (those that create/modify data).
const _quickQueryExcludedSkills = {
  'submit_record',
  'manage_timeline_card',
  'dynamic_timeline_ui',
  'timeline_diagnostics',
  'ask_clarification',
};

const _loopBudgetWarningTurns = 6;
const _loopBudgetToolCutoffTurns = 10;

const _loopBudgetReminder = '''
## Current Turn Tool Budget
You have already used several tool rounds in this single user turn.

Stop broad exploration now and answer the user with the best current conclusion. Do not call more tools unless the next tool is a clearly required write/retry action that directly completes the user's requested task.

For Timeline/card/image/UI issues:
- Do not continue with generic Grep, Glob, Read, BatchRead, or LS after timeline_diagnostics has already inspected the target.
- Report what was checked, what is known from local data/render-path diagnostics, what remains unverified visually, and one concrete next step.
- If the target is still unclear, ask for the screenshot or exact card id instead of searching unrelated Cards, PKM, or _UserSettings files.
''';

class SuperAgent {
  static final Logger _logger = getLogger('SuperAgent');

  /// File-tool permission rules for the SuperAgent workspace.
  ///
  /// The whole workspace is writable (read-only in Quick Query), with one
  /// carve-out the system prompt has always declared but never enforced:
  /// `Facts/` holds the user's immutable raw records and is never writable
  /// through generic file tools — records are created via the submit_record
  /// pipeline, which writes through FileSystemService directly and is not
  /// affected by these rules. `Facts/assets/` stays writable because derived
  /// analysis sidecars (`.analysis.txt`, `.ocr.txt`) live there and the
  /// correction flow must be able to update them.
  @visibleForTesting
  static List<PermissionRule> buildPermissionRules({
    required String workspacePath,
    required String factsPath,
    required String factsAssetsPath,
    required bool quickQuery,
  }) {
    return [
      PermissionRule(
          rootPath: workspacePath,
          access: quickQuery ? FileAccessType.read : FileAccessType.write),
      PermissionRule(rootPath: factsPath, access: FileAccessType.read),
      PermissionRule(
          rootPath: factsAssetsPath,
          access: quickQuery ? FileAccessType.read : FileAccessType.write),
    ];
  }

  /// Whether this agent operates in read-only Quick Query mode.
  static Future<StatefulAgent> createAgent(
      {required LLMClient client,
      required ModelConfig modelConfig,
      required String userId,
      required String name,
      required AgentState state,
      AgentController? controller,
      List<String>? forceActiveSkills,
      bool disableSubAgents = false,
      bool quickQuery = false,
      String? additionalSystemPrompt}) async {
    final fileService = FileSystemService.instance;

    controller = controller ?? AgentController();
    addAgentLogger(controller);
    addAgentActivityCollector(controller);

    final workingDirectory = fileService.getWorkspacePath(userId);

    final permissionManager = FilePermissionManager(
      userId,
      buildPermissionRules(
        workspacePath: fileService.getWorkspacePath(userId),
        factsPath: fileService.getFactsPath(userId),
        factsAssetsPath: fileService.getAssetsPath(userId),
        quickQuery: quickQuery,
      ),
    );

    final fileToolFactory = FileToolFactory(
      permissionManager: permissionManager,
      workingDirectory: workingDirectory,
    );

    final allTools = [
      fileToolFactory.buildLSTool(),
      fileToolFactory.buildGlobTool(),
      fileToolFactory.buildGrepTool(),
      fileToolFactory.buildReadTool(),
      fileToolFactory.buildBatchReadTool(),
      fileToolFactory.buildWriteTool(),
      fileToolFactory.buildMoveTool(),
      fileToolFactory.buildRemoveTool(),
      fileToolFactory.buildEditTool(),
      buildSearchEventLogsTool(),
      getCurrentTimeTool,
      getPkmOverviewTool
    ];

    // Filter tools in Quick Query mode — only keep read-only tools
    final tools = quickQuery
        ? allTools.where((t) => _readOnlyToolNames.contains(t.name)).toList()
        : allTools;

    // Memory Management (skip write tools in Quick Query mode)
    final memoryManagement = await MemoryManagement.createDefault(
      userId: userId,
      sourceAgent: name,
    );
    final memorySystemPrompt = quickQuery
        ? await memoryManagement.buildMemoryReadOnlyPrompt()
        : await memoryManagement.buildSuperAgentMemoryManagementPrompt();
    if (!quickQuery) {
      final memoryManagementTools =
          memoryManagement.buildMemoryManagementTools();
      tools.addAll(memoryManagementTools);
    }

    final userMemory = await memoryManagement.buildMemoryPrompt();
    state.systemReminders["user_memory"] = userMemory;

    var skills = [
      SubmitRecordSkill(),
      KnowledgeInsightSkill(),
      TimelineCardSkill(),
      DynamicTimelineUiSkill(),
      TimelineDiagnosticsSkill(),
      PkmSkill(workingDirectory: '/PKM'),
      SystemActionSkill(),
      AskClarificationSkill(),
    ];
    if (quickQuery) {
      skills = skills
          .where((s) => !_quickQueryExcludedSkills.contains(s.name))
          .toList();
    }
    if (forceActiveSkills != null) {
      for (var skill in skills) {
        if (forceActiveSkills.contains(skill.name)) {
          skill.forceActivate = true;
        }
      }
    }

    final systemPrompts = [superAgentSystemPrompt, memorySystemPrompt];
    if (quickQuery) {
      systemPrompts.add(
        '## Quick Query Mode\n'
        'You are in **Quick Query** (read-only) mode. You can ONLY read and search existing data.\n'
        'You MUST NOT create, modify, or delete any records, cards, knowledge entries, or files.\n'
        'If the user asks you to create or change something, explain that this is a read-only mode '
        'and suggest they use the full Chat mode instead.',
      );
    }
    if (additionalSystemPrompt != null) {
      systemPrompts.add(additionalSystemPrompt);
    }

    final agent = StatefulAgent(
        name: name,
        client: client,
        modelConfig: modelConfig,
        state: state,
        // Claude Code-style fixed-quota compaction. Same quota as the core
        // default; the wrapper only strips image bytes from already-archived
        // episodic messages (retrieve_memory can only return text anyway).
        compressor: SuperAgentContextCompressor(
          client: client,
          modelConfig: modelConfig,
          totalTokenThreshold: 64000,
          keepRecentMessageSize: 10,
        ),
        tools: tools,
        skills: skills,
        systemPrompts: systemPrompts,
        disableSubAgents: true,
        controller: controller,
        withGeneralPrinciples: true,
        planMode: PlanMode.auto,
        autoSaveStateFunc: (state) async {
          await saveAgentState(state);
        },
        systemCallback: _createSuperAgentSystemCallback(userId));

    _logger.info(
        'SuperAgent created, userId: $userId, sessionId: ${state.sessionId}');
    return agent;
  }

  static SystemCallback _createSuperAgentSystemCallback(String userId) {
    final baseCallback = createSystemCallback(userId);
    return (
      StatefulAgent agent,
      SystemMessage? systemMessage,
      List<Tool> tools,
      List<LLMMessage> requestMessages,
    ) async {
      final result = await baseCallback(
        agent,
        systemMessage,
        tools,
        requestMessages,
      );

      var nextSystemMessage = result.systemMessage;
      var nextTools = result.tools;
      if (agent.state.currentLoopCount >= _loopBudgetWarningTurns) {
        nextSystemMessage = SystemMessage(
          [
            if (nextSystemMessage != null) nextSystemMessage.content,
            _loopBudgetReminder,
          ].join('\n\n'),
        );
      }

      if (agent.state.currentLoopCount >= _loopBudgetToolCutoffTurns) {
        nextTools = const [];
      }

      // Deliver any images a tool stashed for the model (e.g. the dynamic
      // timeline UI render preview). They cannot ride in the tool result —
      // OpenAI-compatible providers reject images there — so inject them as a
      // UserMessage on this call only. requestMessages is a per-call copy of
      // state.history, so this is never persisted into the agent state.
      var nextRequestMessages = result.requestMessages;
      final pendingImages =
          PendingToolImageBuffer.instance.drain(agent.state.sessionId);
      if (pendingImages.isNotEmpty) {
        nextRequestMessages = [
          ...nextRequestMessages,
          UserMessage([
            TextPart(
              'Rendered preview(s) of the dynamic timeline card HTML you '
              'generated. Inspect now and decide this turn:',
            ),
            ...pendingImages,
          ]),
        ];
      }

      return SystemCallbackResult(
        systemMessage: nextSystemMessage,
        tools: nextTools,
        requestMessages: nextRequestMessages,
      );
    };
  }
}
