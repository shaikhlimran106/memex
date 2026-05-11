import 'dart:convert';
import 'dart:io';
import 'package:memex/agent/memory/memory_management.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/utils/user_storage.dart';

import 'package:path/path.dart' as p;

import 'package:memex/agent/agent_controller.util.dart';
import 'package:memex/agent/built_in_tools/file_tools.dart';
import 'package:memex/agent/security/file_permission_manager.dart';
import 'package:memex/agent/pkm_agent/prompts.dart';
import 'package:memex/agent/pkm_agent/pkm_stats_service.dart';
import 'package:memex/agent/state_util.dart';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/agent/agent_system_prompt_helper.dart';
import 'package:memex/agent/skills/manage_pkm/pkm_skill.dart';
import 'package:memex/agent/skills/manage_system_action/system_action_skill.dart';
import 'package:memex/agent/skills/ask_clarification/ask_clarification_skill.dart';
import 'package:memex/data/services/file_operation_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:logging/logging.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/agent/agent_cache_helper.dart';

class PkmAgent {
  static final Logger _logger = getLogger('PkmAgent');

  static Future<StatefulAgent> createAgent({
    required LLMClient client,
    required ModelConfig modelConfig,
    required String userId,
    required String factId,
  }) async {
    final fileService = FileSystemService.instance;

    // Match backend task_id format: {user_id}_{fact_id_safe}
    final factIdSafe = fileService.makeFactIdSafe(factId);
    final sessionId = "pkm_${userId}_$factIdSafe";

    // Load or create agent state
    final state = await loadOrCreateAgentState(sessionId, {
      'userId': userId,
      'factId': factId,
      'scene': 'input',
      'sceneId': factId,
    });

    final controller = AgentController();
    addAgentLogger(controller);
    addAgentActivityCollector(controller);

    final stopAfterUpdateCardInsightRef = [true];
    final skills = [
      PkmSkill(
        forceActivate: true,
        stopAfterUpdateCardInsightRef: stopAfterUpdateCardInsightRef,
        workingDirectory: '/',
      ),
      SystemActionSkill(forceActivate: true),
      AskClarificationSkill(),
    ];

    final pkmPath = '${fileService.getWorkspacePath(userId)}/PKM';
    final pkmDir = Directory(pkmPath);
    if (!pkmDir.existsSync()) {
      pkmDir.createSync(recursive: true);
    }

    // Get working directory (Workspace Root)
    final workingDirectory = fileService.getPkmPath(userId);

    // Configure File Permission Manager
    // PkmAgent has access to:
    // - Write: /PKM (Primary workspace)
    final permissionManager = FilePermissionManager(userId, [
      PermissionRule(
          rootPath: fileService.getPkmPath(userId),
          access: FileAccessType.write),
    ]);

    final fileToolFactory = FileToolFactory(
      permissionManager: permissionManager,
      workingDirectory: workingDirectory,
    );

    final plainReadTool = fileToolFactory.buildReadTool();
    final readTool = Tool(
      name: plainReadTool.name,
      description: plainReadTool.description,
      parameters: plainReadTool.parameters,
      executable: (String filePath, int? offset, int? limit) async {
        // Resolve path only for permission check (needs absolute path)
        // FileOperationService methods will handle path resolution internally
        String resolvedPath;
        if (filePath.startsWith(workingDirectory)) {
          resolvedPath = filePath;
        } else if (filePath.startsWith('/')) {
          resolvedPath = filePath == '/'
              ? workingDirectory
              : p.join(workingDirectory, filePath.substring(1));
        } else {
          resolvedPath = p.join(workingDirectory, filePath);
        }

        // Check permission (requires absolute path)
        permissionManager.checkPermission(resolvedPath, FileAccessType.read);

        // Pass original filePath to readFile - it will resolve internally
        final result = await FileOperationService.instance.readFile(
          filePath: filePath,
          workingDirectory: workingDirectory,
          offset: offset ?? 1,
          limit: limit,
        );

        final reminders = <String>[];

        // 1. Line count check
        final lineCount = '\n'.allMatches(result).length + 1;
        if (lineCount >= 2000) {
          reminders.add(
              '<system-reminder>The file "$filePath" contains $lineCount lines, which exceeds the 2000-line limit. Please adjust this file to ensure it complies with the P.A.R.A. structure requirement after the input is processed.</system-reminder>');
        } else if (lineCount > 1000) {
          reminders.add(
              '<system-reminder>The file "$filePath" contains $lineCount lines. Please consider whether the P.A.R.A. structure is reasonable after the input is processed.</system-reminder>');
        }

        // 2. Directory fragmentation check
        try {
          // Use filePath's parent directory - grepFiles will resolve internally
          final parentDirDisplay = p.dirname(filePath);

          // Use grepFiles with r: false to get fact_id counts in current directory only
          // Pass parentDirDisplay (model's perspective path) - grepFiles will resolve internally
          final grepResult = await FileOperationService.instance.grepFiles(
            pattern: 'fact_id',
            searchPath: parentDirDisplay,
            workingDirectory: workingDirectory,
            outputMode: 'count',
            r: false, // Non-recursive: only search current directory
          );

          final matchCounts = <String, int>{};
          if (!grepResult.startsWith('No matches found')) {
            final lines = grepResult.split('\n');
            for (final line in lines) {
              // Filter truncated message if exists
              if (line.startsWith('(Output limited')) continue;

              final lastColon = line.lastIndexOf(':');
              if (lastColon != -1) {
                final fPath = line.substring(0, lastColon).trim();
                final countStr = line.substring(lastColon + 1).trim();
                try {
                  matchCounts[fPath] = int.parse(countStr);
                } catch (e) {
                  // ignore parse error
                }
              }
            }
          }

          // Count files with 2 or fewer fact_id references
          int fragmentedFilesCount = 0;
          final fragmentedFileInfos = <String>[];

          for (final entry in matchCounts.entries) {
            final count = entry.value;
            if (count <= 1) {
              fragmentedFilesCount++;
              fragmentedFileInfos.add('${p.basename(entry.key)} ($count)');
            }
          }

          if (fragmentedFilesCount > 5) {
            reminders.add(
                '<system-reminder>The directory "$parentDirDisplay" contains $fragmentedFilesCount files with only one fact_id reference each: ${fragmentedFileInfos.join(", ")}. Please consider adjusting the file structure to avoid excessive fragmentation after the input is processed.</system-reminder>');
          }
        } catch (e) {
          // Ignore directory errors (e.g., parent dir doesn't exist or access denied)
          // FileOperationService will handle path validation
        }

        // 3. Filename date check
        final filename = p.basename(filePath);
        // Strict date check: 20XX year, 01-12 month, 01-31 day
        if (RegExp(r'20\d{2}-?(?:0[1-9]|1[0-2])-?(?:0[1-9]|[12]\d|3[01])')
            .hasMatch(filename)) {
          reminders.add(
              '<system-reminder>The file "$filename" contains a date in its filename. Please determine if this filename is reasonable after the input is processed.</system-reminder>');
        }

        // 4. Frequent edit check
        try {
          final editCount = await PkmStatsService.instance
              .getRecentEditCount(userId, filePath);
          if (editCount >= 3) {
            final bool hasDatePattern = RegExp(r'(20\d{2})').hasMatch(filename);
            if (hasDatePattern) {
              reminders.add(
                  '<system-reminder>The file "${p.basename(filePath)}" has been modified in $editCount of the last 5 inputs and contains a date in its name. This frequent activity suggests it is being used as a time-based log (e.g., "YYYY_MM_Life"). Please consider renaming it to a topic-based name or splitting it to improve organization after the input is processed.</system-reminder>');
            } else {
              reminders.add(
                  '<system-reminder>The file "${p.basename(filePath)}" has been modified in $editCount of the last 5 inputs. This frequent activity suggests the filename is too generic (e.g., "Image Record", "Notes"). Please consider renaming it to be more specific or splitting it to improve organization after the input is processed.</system-reminder>');
            }
          }
        } catch (e) {
          // Ignore stats service errors
        }

        if (reminders.isNotEmpty) {
          stopAfterUpdateCardInsightRef[0] = false;
          return '$result\n\n${reminders.join('\n')}';
        }
        return result;
      },
    );

    final tools = [
      readTool,
      fileToolFactory.buildBatchReadTool(),
      fileToolFactory.buildWriteTool(),
      fileToolFactory.buildEditTool(),
      fileToolFactory.buildMoveTool(),
      fileToolFactory.buildRemoveTool(),
      fileToolFactory.buildLSTool(),
      fileToolFactory.buildGlobTool(),
      fileToolFactory.buildGrepTool(),
      // getPkmOverviewTool
    ];

    // Memory Management (Read-Only)
    final memoryManagement = await MemoryManagement.createDefault(
      userId: userId,
      sourceAgent: 'pkm_agent',
    );
    // REMOVED: buildMemoryManagementPrompt() - PkmAgent should not have the complex memory instructions
    // REMOVED: buildMemoryManagementTools() - PkmAgent cannot write to memory
    // tools.addAll(memoryManagementTools);

    final userMemory = await memoryManagement.buildMemoryPrompt();
    state.systemReminders["user_memory"] = userMemory;

    final agent = StatefulAgent(
        name: 'pkm_agent',
        client: client,
        modelConfig: modelConfig,
        state: state,
        compressor: LLMBasedContextCompressor(
          client: client,
          modelConfig: modelConfig,
          totalTokenThreshold: 64000,
          keepRecentMessageSize: 10,
        ),
        tools: tools,
        skills: skills,
        systemPrompts: [pkmAgentSystemPrompt],
        disableSubAgents: true,
        controller: controller,
        withGeneralPrinciples: true,
        planMode: PlanMode.none,
        autoSaveStateFunc: (state) async {
          await saveAgentState(state);
        },
        systemCallback: createSystemCallback(userId));

    _logger.info('PkmAgent created, userId: $userId, sessionId: $sessionId');
    return agent;
  }

  /// Static method to run the agent with user message
  /// This method handles responseId caching and agent initialization internally
  static Future<void> runWithContent({
    required LLMClient client,
    required ModelConfig modelConfig,
    required String userId,
    required String factId,
    required String instruction,
  }) async {
    // Ensure we have a valid cached responseId with matching hashCode
    final cachedResponseId = await AgentCacheHelper.ensureValidCachedResponseId(
      agentType: 'pkm',
      client: client,
      modelConfig: modelConfig,
      agentFactory: ({
        required LLMClient client,
        required ModelConfig modelConfig,
      }) =>
          createAgent(
        client: client,
        modelConfig: modelConfig,
        userId: "mocked_user_id",
        factId: "mocked_fact_id_${DateTime.now().millisecondsSinceEpoch}",
      ),
    );

    // Prepare modelConfig for actual run (with reasoning only, and previous_response_id if available)
    final extra = Map<String, dynamic>.from(modelConfig.extra ?? {});
    if (cachedResponseId != null) {
      extra['previous_response_id'] = cachedResponseId;
    }

    final finalModelConfig = ModelConfig(
      model: modelConfig.model,
      extra: extra,
      temperature: modelConfig.temperature,
      maxTokens: modelConfig.maxTokens,
      topP: modelConfig.topP,
      topK: modelConfig.topK,
      generationConfig: modelConfig.generationConfig,
    );

    final agent = await createAgent(
      client: client,
      modelConfig: finalModelConfig,
      userId: userId,
      factId: factId,
    );

    final pkmOverview = await _getPkmOverview(userId);

    final input = [
      UserMessage([
        TextPart('''$pkmOverview
<system-reminder>
${UserStorage.l10n.userLanguageInstruction}
</system-reminder>.

$instruction
'''),
      ])
    ];

    // Run the agent (with retry when P.A.R.A write or insight update is missing)
    final wasRunning = agent.state.isRunning;
    const maxRetries = 3;
    var runCount = 0;
    List<LLMMessage> messagesToRun = input;

    while (true) {
      runCount++;
      if (runCount == 1 && wasRunning) {
        _logger.info(
            "PkmAgent resume (attempt $runCount/${maxRetries + 1}), sessionId:${agent.state.sessionId}");
        await agent.resume(useStream: false);
      } else {
        _logger.info(
            "PkmAgent run (attempt $runCount/${maxRetries + 1}), sessionId:${agent.state.sessionId}");
        await agent.run(messagesToRun, useStream: false);
      }

      if (runCount == 1) {
        try {
          final fileSystem = FileSystemService.instance;
          await fileSystem.eventLogService.logEvent(
            userId: userId,
            eventType: 'agent_execution',
            description: 'PKM Agent started',
            metadata: {
              'agent_name': 'pkm_agent',
              'session_id': agent.state.sessionId,
              'fact_id': agent.state.metadata['factId'],
            },
          );
        } catch (e) {
          // Event logging failure should not break agent execution
        }
      }

      if (runCount > maxRetries) break;

      final factId = agent.state.metadata['factId'] as String?;
      if (factId == null) break;

      final check = _checkPkmRunComplete(agent.state.history.messages, factId);
      if (check.wrotePara && check.updatedInsight) break;

      final reminderParts = <String>[];
      if (!check.wrotePara) {
        reminderParts.add(
            'Write to P.A.R.A.: use the Write or Edit tool to organize the current raw input under / and record the current fact_id in the file (e.g. as a comment: <!-- fact_id: ... -->)');
      }
      if (!check.updatedInsight) {
        reminderParts.add(
            'Update the Timeline Card insight: use the update_timeline_card_insight tool to complete the New Raw Input Organization Task (this call is required to mark the workflow as complete)');
      }
      final reminderText = reminderParts.map((s) => '- $s').join('\n');
      messagesToRun = [
        UserMessage([
          TextPart(
              '<system-reminder>The following required steps are still incomplete. You must complete both before finishing:\n$reminderText</system-reminder>'),
        ])
      ];
    }

    // Record edits for this session
    try {
      final editedFiles = <String>{};
      for (final msg in agent.state.history.messages) {
        if (msg is! FunctionExecutionResultMessage) continue;
        for (final r in msg.results) {
          if (r.isError) continue;
          if (r.name == 'Write' || r.name == 'Edit') {
            // arguments is a Map<String, dynamic> usually, or JSON string.
            // The tool definition says parameters are maps.
            // But DartAgentCore ToolResult.arguments is Map<String, dynamic>.
            // Let's verify how arguments are stored.
            // ToolResult arguments are Map<String, dynamic>.
            // The tools (Write, Edit) have 'target_file' or similar as first arg.
            // Wait, standard file tools usually use 'file_path' or 'path'.
            // Let's check FileToolFactory definitions or just infer from usage.
            // 'Write' tool usually has 'file_path' or 'target_file'.
            // 'Edit' tool usually has 'file_path' or 'target_file'.
            // Let's check the file_tools.dart if possible, or assume 'file_path' based on Read tool usage.

            // In FileTools:
            // Write: 'file_path'
            // Edit: 'file_path'

            try {
              final args = jsonDecode(r.arguments) as Map<String, dynamic>;
              if (args.containsKey('file_path')) {
                editedFiles.add(args['file_path'] as String);
              }
            } catch (e) {
              // Ignore JSON parse errors or invalid format
            }
          }
        }
      }
      await PkmStatsService.instance
          .recordSessionEdits(userId, editedFiles.toList());
    } catch (e) {
      _logger.warning('Failed to record session edits: $e');
    }
  }

  /// Returns whether history contains successful write/edit (with fact_id) and
  /// successful update_timeline_card_insight.
  static ({bool wrotePara, bool updatedInsight}) _checkPkmRunComplete(
    List<LLMMessage> messages,
    String factId,
  ) {
    bool wrotePara = false;
    bool updatedInsight = false;
    for (final msg in messages) {
      if (msg is! FunctionExecutionResultMessage) continue;
      for (final r in msg.results) {
        if (r.isError) continue;
        if ((r.name == 'Write' || r.name == 'Edit') &&
            r.arguments.contains(factId)) {
          wrotePara = true;
        }
        if (r.name == 'update_timeline_card_insight') {
          updatedInsight = true;
        }
      }
    }
    return (wrotePara: wrotePara, updatedInsight: updatedInsight);
  }

  static Future<String> _getPkmOverview(String userId) async {
    final fileService = FileSystemService.instance;
    final fileOpService = FileOperationService.instance;

    final workingDirectory = fileService.getPkmPath(userId);
    final pkmPath = fileService.getPkmPath(userId);
    final pkmDir = Directory(pkmPath);

    String pkmStructure = '';
    try {
      if (pkmDir.existsSync()) {
        pkmStructure = await fileOpService.listDirectory(
          dirPath: pkmPath,
          workingDirectory: workingDirectory,
        );
      } else {
        pkmStructure =
            '<system-reminder>${Prompts.pkmAgentDirectoryNotCreated}</system-reminder>';
      }
    } catch (e) {
      _logger.warning('Failed to get PKM structure: $e');
      pkmStructure =
          '<system-reminder>${Prompts.pkmAgentDirectoryStructureError(e.toString())}</system-reminder>';
    }

    final header = pkmStructure.contains('passing a specific path')
        ? Prompts.pkmAgentTruncatedOverviewHeader
        : Prompts.pkmAgentFullOverviewHeader;
    return '''<system-reminder>
$header
$pkmStructure
</system-reminder>''';
  }
}
