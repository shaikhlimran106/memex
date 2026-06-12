import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AgentBackgroundStatus', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({'language': 'en'});
      await UserStorage.initL10n();
    });

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
      expect(status.taskSummary, 'Running 1, Pending 2, Retry 1');
      expect(status.detail, 'Processing 4 queued task(s).');
      expect(
        status.toPlatformMap(isInBackground: true),
        containsPair('remainingTasks', 4),
      );
      expect(
        status.toPlatformMap(isInBackground: true),
        containsPair('taskSummary', 'Running 1, Pending 2, Retry 1'),
      );
      expect(
        status.toPlatformMap(isInBackground: true),
        containsPair('statusText', 'Running 1, Pending 2, Retry 1'),
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

    test('prefers durable run stage and progress over generic task detail', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 1,
          processing: 1,
          retrying: 0,
        ),
        runSnapshot: AgentRunSnapshot(
          id: 'run-1',
          userId: 'user-a',
          factId: 'fact-1',
          state: AgentRunState.running,
          stage: 'Generating card',
          message: 'Turning the record into a timeline card.',
          completedUnits: 30,
          totalUnits: 100,
          remainingTasks: 2,
          updatedAt: DateTime(2026, 1, 1),
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.state, AgentBackgroundRunState.active);
      expect(status.stage, 'Generating card');
      expect(status.detail, 'Turning the record into a timeline card.');
      expect(status.progressCompleted, 30);
      expect(status.progressTotal, 100);
      expect(status.runId, 'run-1');
      expect(status.factId, 'fact-1');
      expect(status.taskSummary, 'Running 1, Pending 1, Retry 0');
      expect(status.toPlatformMap(), containsPair('state', 'active'));
      expect(status.toPlatformMap(), containsPair('progressCompleted', 30));
    });

    test('maps paused durable run to a visible paused platform status', () {
      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot.empty(),
        runSnapshot: AgentRunSnapshot(
          id: 'run-2',
          userId: 'user-a',
          factId: 'fact-2',
          state: AgentRunState.pausedBySystem,
          stage: 'Paused',
          message: 'Background time expired. Memex will continue later.',
          completedUnits: 65,
          totalUnits: 100,
          remainingTasks: 3,
          updatedAt: DateTime(2026, 1, 1),
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.state, AgentBackgroundRunState.paused);
      expect(status.shouldShowSystemSurface, isTrue);
      expect(status.remainingTasks, 3);
      expect(status.taskSummary, 'Running 0, Pending 3, Retry 0');
      expect(status.detail, contains('continue later'));
      expect(status.toPlatformMap(), containsPair('state', 'paused'));
      expect(
        status.toPlatformMap(),
        containsPair('taskSummary', 'Running 0, Pending 3, Retry 0'),
      );
    });

    test('localizes platform summary text from current locale', () async {
      await UserStorage.setLocale(const Locale('zh'));

      final status = AgentBackgroundStatus.fromActivity(
        taskSnapshot: const TaskActivitySnapshot(
          pending: 2,
          processing: 1,
          retrying: 1,
        ),
        now: DateTime(2026, 1, 1),
      );

      expect(status.title, 'Memex Agent');
      expect(status.stage, '处理中');
      expect(status.taskSummary, '执行中 1，排队中 2，重试中 1');
      expect(status.statusText, '执行中 1，排队中 2，重试中 1');
      expect(
        status.toPlatformMap(),
        containsPair('statusText', '执行中 1，排队中 2，重试中 1'),
      );
    });
  });
}
