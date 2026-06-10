import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/local_task_executor.dart';

void main() {
  group('AgentBackgroundStatus', () {
    test('stays idle when there are no tasks or terminal messages', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot.empty(),
        now: DateTime(2026, 1, 1),
      );

      expect(status.state, AgentBackgroundRunState.idle);
      expect(status.shouldShowSystemSurface, isFalse);
      expect(status.remainingTasks, 0);
      expect(status.detail, 'No background tasks.');
    });

    test('uses task snapshot counts for active status', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 2,
          processing: 1,
          retrying: 1,
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.state, AgentBackgroundRunState.active);
      expect(status.remainingTasks, 4);
      expect(status.title, 'Memex Agent');
      expect(status.detail, 'Processing 4 queued tasks');
      expect(
        status.toPlatformMap(isInBackground: true),
        containsPair('remainingTasks', 4),
      );
      expect(
        status.toPlatformMap(isInBackground: true),
        containsPair('isInBackground', true),
      );
    });

    test('keeps retryable error visible as active while tasks remain', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 0,
          processing: 0,
          retrying: 1,
        ),
        latestMessage: AgentActivityMessageModel(
          id: 1,
          type: AgentActivityType.error,
          title: 'Provider timeout',
          content: 'Will retry automatically',
          agentName: 'Insight Agent',
          agentId: 'insight',
          timestamp: DateTime(2026, 1, 1),
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.state, AgentBackgroundRunState.active);
      expect(status.stage, 'Provider timeout');
      expect(status.detail, 'Will retry automatically');
    });

    test('marks terminal stop as completed only after queue is empty', () {
      final message = AgentActivityMessageModel(
        id: 2,
        type: AgentActivityType.agent_stop,
        title: 'Done',
        agentName: 'Card Agent',
        agentId: 'card',
        timestamp: DateTime(2026, 1, 1),
      );

      final stillRunning = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 1,
          processing: 0,
          retrying: 0,
        ),
        latestMessage: message,
        now: DateTime(2026, 1, 1),
      );
      final completed = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot.empty(),
        latestMessage: message,
        now: DateTime(2026, 1, 1),
      );

      expect(stillRunning.state, AgentBackgroundRunState.active);
      expect(completed.state, AgentBackgroundRunState.completed);
      expect(completed.shouldShowSystemSurface, isFalse);
      expect(completed.detail, 'All background tasks finished.');
    });

    test('trims multi-line content before sending to platform', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 0,
          processing: 1,
          retrying: 0,
        ),
        latestMessage: AgentActivityMessageModel(
          id: 3,
          type: AgentActivityType.info,
          title: 'Long output',
          content: '${'a' * 80}\n${'b' * 80}',
          agentName: 'PKM Agent',
          agentId: 'pkm',
          timestamp: DateTime(2026, 1, 1),
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.detail, hasLength(140));
      expect(status.detail, endsWith('...'));
      expect(status.detail.contains('\n'), isFalse);
    });
  });
}
