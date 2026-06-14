import 'dart:async';
import 'dart:convert';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/data/services/schedule_state_service.dart';
import 'package:memex/data/services/system_action_service.dart';
import 'package:memex/agent/schedule_aggregator_agent/schedule_aggregator_agent.dart';
import 'package:memex/domain/models/schedule_state.dart';
import 'package:memex/domain/models/task_exceptions.dart';

final Logger _logger = getLogger('LocalTaskHandlers');

/// Handler for Schedule Aggregation Update
Future<void> handleScheduleAggregation(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
) async {
  _logger.info(
    'Executing handleScheduleAggregation for task ${context.taskId}, bizId: ${context.bizId}',
  );

  try {
    final beforeState = await ScheduleStateService.instance.read(userId);
    final beforeSystemActions =
        await SystemActionService.instance.getVisibleForSchedule();
    final factId = payload['fact_id'] as String?;
    final runId = factId != null && factId.isNotEmpty ? factId : context.taskId;
    await ScheduleAggregatorAgent.updateScheduleAggregation(
      userId: userId,
      runId: runId,
      routerHint: payload,
    );
    final afterState = await ScheduleStateService.instance.read(userId);
    final afterSystemActions =
        await SystemActionService.instance.getVisibleForSchedule();
    await LocalTaskExecutor.instance.updateTaskResult(
      context.taskId,
      jsonEncode(
        _buildScheduleAggregationResult(
          beforeState: beforeState,
          afterState: afterState,
          beforeSystemActionCount: beforeSystemActions.length,
          afterSystemActionCount: afterSystemActions.length,
          sourceFactId: factId,
        ),
      ),
    );
  } on AgentException catch (e) {
    if (e.code == AgentExceptionCode.loopDetection) {
      _logger.severe('Schedule aggregation loop detected: $e');
      throw NonRetryableAgentLoopException(
        'Schedule aggregation reached the max-turn guard.',
        originalError: e,
      );
    }
    rethrow;
  } catch (e) {
    _logger.severe('Schedule aggregation failed: $e');
    rethrow;
  }
}

Map<String, dynamic> _buildScheduleAggregationResult({
  required ScheduleState beforeState,
  required ScheduleState afterState,
  required int beforeSystemActionCount,
  required int afterSystemActionCount,
  required String? sourceFactId,
}) {
  final beforeBySource = _pendingBySourceFactId(beforeState);
  final afterBySource = _pendingBySourceFactId(afterState);
  final addedSourceIds = afterBySource.keys
      .where((sourceId) => !beforeBySource.containsKey(sourceId));
  final updatedSourceIds = afterBySource.keys.where(
    (sourceId) =>
        beforeBySource.containsKey(sourceId) &&
        beforeBySource[sourceId] != afterBySource[sourceId],
  );

  return {
    'completed': true,
    if (sourceFactId != null && sourceFactId.isNotEmpty)
      'source_fact_id': sourceFactId,
    'schedule_items': {
      'pending_before': beforeState.pending.length,
      'pending_after': afterState.pending.length,
      'pending_delta': afterState.pending.length - beforeState.pending.length,
      'added_source_fact_ids': addedSourceIds.toList(),
      'updated_source_fact_ids': updatedSourceIds.toList(),
      'completed_before': beforeState.completed.length,
      'completed_after': afterState.completed.length,
      'completed_delta':
          afterState.completed.length - beforeState.completed.length,
    },
    'system_actions': {
      'visible_before': beforeSystemActionCount,
      'visible_after': afterSystemActionCount,
      'visible_delta': afterSystemActionCount - beforeSystemActionCount,
    },
  };
}

Map<String, String> _pendingBySourceFactId(ScheduleState state) {
  final result = <String, String>{};
  for (final item in state.pending) {
    final itemJson = jsonEncode(item.toJson());
    for (final sourceFactId in item.sourceFactIds) {
      result[sourceFactId] = itemJson;
    }
  }
  return result;
}
