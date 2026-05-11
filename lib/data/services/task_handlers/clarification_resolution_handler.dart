import 'package:logging/logging.dart';
import 'package:memex/agent/clarification_resolution_agent/clarification_resolution_agent.dart';
import 'package:memex/agent/memory/memory_management.dart';
import 'package:memex/data/services/clarification_request_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

final Logger _logger = getLogger('ClarificationResolutionHandler');

Future<void> handleClarificationResolution(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
) async {
  final requestId = payload['request_id'] as String?;
  if (requestId == null || requestId.isEmpty) {
    throw ArgumentError('request_id is required');
  }

  final service = ClarificationRequestService.instance;
  final request = await service.getRequest(requestId);
  if (request == null) {
    _logger.warning('Clarification request $requestId not found');
    return;
  }

  if (request.status != ClarificationRequestStatus.answered) {
    _logger.info(
        'Clarification request $requestId has status ${request.status}, skipping');
    return;
  }

  final answerData = service.decodeAnswerData(request);
  final options = service.decodeOptions(request);
  final evidenceFactIds = service.decodeEvidenceFactIds(request);

  if ((request.resolutionTarget ?? 'auto') == 'none') {
    await service.updateStatus(requestId, ClarificationRequestStatus.completed);
    return;
  }

  try {
    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.clarificationResolutionAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );

    await ClarificationResolutionAgent.run(
      client: resources.client,
      modelConfig: resources.modelConfig,
      userId: userId,
      request: request,
      answerData: answerData,
      options: options,
      evidenceFactIds: evidenceFactIds,
    );
  } catch (e, st) {
    _logger.warning(
      'Resolution agent failed for $requestId; using deterministic fallback: $e',
      e,
      st,
    );
    final fallbackMemory = _buildFallbackMemory(
      request: request,
      answerData: answerData,
      options: options,
    );
    if (fallbackMemory != null && fallbackMemory.trim().isNotEmpty) {
      final memoryManagement = await MemoryManagement.createDefault(
        userId: userId,
        sourceAgent: 'clarification_resolution_fallback',
      );
      await memoryManagement.appendMemories([fallbackMemory.trim()]);
    }
  }

  await service.updateStatus(requestId, ClarificationRequestStatus.completed);
}

String? _buildFallbackMemory({
  required ClarificationRequest request,
  required Map<String, dynamic> answerData,
  required List<Map<String, dynamic>> options,
}) {
  final target = request.resolutionTarget ?? 'auto';
  if (target != 'auto' && target != 'memory') return null;

  final selectedOptionIds =
      (answerData['option_ids'] as List?)?.map((e) => e.toString()).toSet() ??
          const <String>{};

  final selectedOptions = options
      .where((option) => selectedOptionIds.contains(option['id']?.toString()))
      .toList();
  final isCustomAnswer = answerData['is_custom_answer'] == true;
  final isUncertain = answerData['is_uncertain'] == true ||
      selectedOptions.any(_isAmbiguousOption);

  if (isUncertain && !isCustomAnswer) return null;
  if (isCustomAnswer ||
      request.responseType == ClarificationResponseType.shortText) {
    return null;
  }

  final optionMemories = isCustomAnswer
      ? const <String>[]
      : selectedOptions
          .where((option) => !_isAmbiguousOption(option))
          .map((option) => option['memory']?.toString().trim())
          .whereType<String>()
          .where((memory) => memory.isNotEmpty)
          .toList();
  if (optionMemories.isNotEmpty) {
    return optionMemories.join('\n');
  }

  final answerText = _answerText(answerData, selectedOptions);
  if (answerText.isEmpty) return null;
  if (_isVagueText(answerText)) return null;

  final proposedMemory = request.proposedMemory;
  if (proposedMemory != null && proposedMemory.trim().isNotEmpty) {
    return proposedMemory
        .replaceAll('{answer}', answerText)
        .replaceAll('{{answer}}', answerText)
        .trim();
  }

  final entityLabel = request.entityLabel;
  if (entityLabel != null && entityLabel.trim().isNotEmpty) {
    final hasChinese = RegExp(r'[\u4e00-\u9fff]').hasMatch(request.question);
    return hasChinese
        ? '$entityLabel：$answerText'
        : '$entityLabel: $answerText';
  }

  return null;
}

String _answerText(
  Map<String, dynamic> answerData,
  List<Map<String, dynamic>> selectedOptions,
) {
  final explicitText = answerData['text']?.toString().trim();
  if (explicitText != null && explicitText.isNotEmpty) return explicitText;

  final labels = selectedOptions
      .map((option) =>
          _nonEmptyString(option['value']) ?? _nonEmptyString(option['label']))
      .whereType<String>()
      .where((label) => label.trim().isNotEmpty)
      .toList();
  return labels.join(', ');
}

String? _nonEmptyString(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

bool _isAmbiguousOption(Map<String, dynamic> option) {
  final normalized = [
    option['id'],
    option['label'],
    option['value'],
  ].whereType<Object>().map((e) => e.toString().toLowerCase()).join(' ');
  return normalized.contains('other') ||
      normalized.contains('custom') ||
      normalized.contains('manual') ||
      normalized.contains('type in') ||
      normalized.contains('write in') ||
      normalized.contains('unknown') ||
      normalized.contains('unsure') ||
      normalized.contains('not sure') ||
      normalized.contains('unclear') ||
      normalized.contains('prefer not to say') ||
      normalized.contains('no update') ||
      normalized.contains('no news') ||
      normalized.contains('none of the above') ||
      normalized.contains('not listed') ||
      normalized.contains('其他') ||
      normalized.contains('其它') ||
      normalized.contains('手动') ||
      normalized.contains('手工') ||
      normalized.contains('自己输入') ||
      normalized.contains('自行输入') ||
      normalized.contains('另一个') ||
      normalized.contains('以上都不是') ||
      normalized.contains('都不是') ||
      normalized.contains('不知道') ||
      normalized.contains('不确定') ||
      normalized.contains('不方便') ||
      normalized.contains('不想说') ||
      normalized.contains('不愿') ||
      normalized.contains('暂时不说') ||
      normalized.contains('还没有消息') ||
      normalized.contains('没有消息') ||
      normalized.contains('无法判断') ||
      normalized.contains('说不清');
}

bool _isVagueText(String text) {
  final normalized = text.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  return normalized == 'other' ||
      normalized == 'custom' ||
      normalized == 'unknown' ||
      normalized == 'unsure' ||
      normalized == 'not sure' ||
      normalized == 'unclear' ||
      normalized == 'prefer not to say' ||
      normalized == 'n/a' ||
      normalized == 'na' ||
      normalized.contains('no update') ||
      normalized.contains('no news') ||
      normalized.contains('不知道') ||
      normalized.contains('不确定') ||
      normalized.contains('不方便') ||
      normalized.contains('不想说') ||
      normalized.contains('不愿') ||
      normalized.contains('暂时不说') ||
      normalized.contains('还没有消息') ||
      normalized.contains('没有消息') ||
      normalized.contains('无法判断') ||
      normalized.contains('说不清');
}
