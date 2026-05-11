import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';
import 'package:memex/agent/agent_controller.util.dart';
import 'package:memex/agent/agent_system_prompt_helper.dart';
import 'package:memex/agent/memory/memory_management.dart';
import 'package:memex/agent/state_util.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

class ClarificationResolutionAgent {
  static final Logger _logger = getLogger('ClarificationResolutionAgent');

  static Future<void> run({
    required LLMClient client,
    required ModelConfig modelConfig,
    required String userId,
    required ClarificationRequest request,
    required Map<String, dynamic> answerData,
    required List<Map<String, dynamic>> options,
    required List<String> evidenceFactIds,
  }) async {
    final memoryManagement = await MemoryManagement.createDefault(
      userId: userId,
      sourceAgent: 'clarification_resolution_agent',
    );
    final existingMemory = await memoryManagement.buildMemoryPrompt();

    final state = await loadOrCreateAgentState(
      'clarification_resolution_${request.id}',
      {
        'userId': userId,
        'requestId': request.id,
        'scene': 'clarification',
        'sceneId': request.id,
        'agentName': 'clarification_resolution_agent',
      },
    );

    final controller = AgentController();
    addAgentLogger(controller);
    addAgentActivityCollector(controller);

    final agent = StatefulAgent(
      name: 'clarification_resolution_agent',
      client: client,
      modelConfig: modelConfig,
      state: state,
      tools: memoryManagement.buildMemoryManagementTools(),
      systemPrompts: [
        '''# Role
You are a Clarification Resolution Agent for Memex.

# Task
The user answered a short question created by another agent. Decide whether this answer should become long-term user memory.

# Rules
1. Only call `append_memories` for stable facts, preferences, relationships, identity, recurring habits, or durable project context.
2. Do not write temporary card-only corrections, one-off labels, or low-value answers to memory.
3. Use the same language as the user's question/answer.
${UserStorage.l10n.userLanguageInstruction}
4. Deduplicate against existing memory context.
5. If a `proposed_memory` template is present and appropriate, use it, replacing `{answer}` with the resolved answer.
6. If an option contains a `memory` field and it is appropriate, prefer that memory text.
7. If `answer.is_custom_answer` is true, ignore `memory` fields from vague/custom options. Concrete selected options may still be used when clearly selected.
8. If the selected option is vague (`manual input`, `other`, `unknown`, `not sure`, `prefer not to say`, etc.) and the user did not provide a specific typed answer, DO NOT call `append_memories`.
9. Never turn a manual/other/unknown choice into a specific relationship, identity, or social category. Generic manual input is not knowledge by itself.
10. Output a short final note after tool use; do not ask another question.
''',
      ],
      disableSubAgents: true,
      controller: controller,
      planMode: PlanMode.none,
      autoSaveStateFunc: (s) async {
        await saveAgentState(state);
      },
      systemCallback: createSystemCallback(userId),
    );

    final payload = {
      'request': {
        'id': request.id,
        'question': request.question,
        'response_type': request.responseType,
        'entity_type': request.entityType,
        'entity_label': request.entityLabel,
        'reason': request.reason,
        'impact': request.impact,
        'confidence': request.confidence,
        'proposed_memory': request.proposedMemory,
        'resolution_target': request.resolutionTarget,
        'fact_id': request.factId,
        'evidence_fact_ids': evidenceFactIds,
        'options': options,
      },
      'answer': answerData,
    };

    _logger.info('Resolving clarification request ${request.id}');
    await agent.run([
      UserMessage([
        TextPart('''
<existing_memory_context>
${existingMemory.isEmpty ? 'No existing memory context available.' : existingMemory}
</existing_memory_context>

<clarification_payload>
${const JsonEncoder.withIndent('  ').convert(payload)}
</clarification_payload>

Resolve this clarification answer. If and only if it is durable user knowledge, call `append_memories`.
''')
      ])
    ], useStream: false);
  }
}
