import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/db/app_database.dart';

void main() {
  late AppDatabase db;
  late AgentRunService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    AppDatabase.setTestInstance(db);
    service = AgentRunService.forTesting(db: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('AgentRunService', () {
    test('tracks a coarse Super Agent run through task boundaries', () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-1');
      await _insertTask(
        db,
        id: 'turn',
        runId: 'fact-1',
        type: 'super_agent_chat_turn_task',
        status: 'pending',
      );
      await _insertTask(
        db,
        id: 'comment',
        runId: 'fact-1',
        type: 'comment_agent_task',
        status: 'pending',
      );

      await service.refreshRunFromTasks('fact-1');
      var run = await _getRun(db, 'fact-1');
      expect(run.state, 'queued');
      expect(run.stage, 'Queued');
      expect(run.remainingTasks, 2);

      await _setTaskStatus(db, 'turn', 'processing');
      await service.markTaskStarted(
        runId: 'fact-1',
        taskId: 'turn',
        taskType: 'super_agent_chat_turn_task',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'running');
      expect(run.stage, 'Running Super Agent');
      expect(run.completedUnits, 20);

      await _setTaskStatus(db, 'turn', 'completed');
      await service.markTaskCompleted(
        runId: 'fact-1',
        taskId: 'turn',
        taskType: 'super_agent_chat_turn_task',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'queued');
      expect(run.stage, 'Queued');
      expect(run.completedUnits, 95);
      expect(run.remainingTasks, 1);

      await _setTaskStatus(db, 'comment', 'processing');
      await service.markTaskStarted(
        runId: 'fact-1',
        taskId: 'comment',
        taskType: 'comment_agent_task',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'running');
      expect(run.stage, 'Preparing comment');
      expect(run.completedUnits, 95);

      await _setTaskStatus(db, 'comment', 'completed');
      await service.markTaskCompleted(
        runId: 'fact-1',
        taskId: 'comment',
        taskType: 'comment_agent_task',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'completed');
      expect(run.stage, 'Completed');
      expect(run.completedUnits, 100);
      expect(run.remainingTasks, 0);
    });

    test('keeps retrying work visible without marking it failed', () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-2');
      await _insertTask(
        db,
        id: 'turn',
        runId: 'fact-2',
        type: 'super_agent_chat_turn_task',
        status: 'retrying',
      );

      await service.markTaskRetrying(
        runId: 'fact-2',
        taskId: 'turn',
        taskType: 'super_agent_chat_turn_task',
        error: Exception('provider timeout'),
      );

      final run = await _getRun(db, 'fact-2');
      expect(run.state, 'queued');
      expect(run.stage, 'Waiting to retry');
      expect(run.message, 'The current step will retry automatically.');
      expect(run.lastError, contains('provider timeout'));
      expect(run.remainingTasks, 1);
    });

    test('marks permanent task failure as a visible needs-attention run',
        () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-3');
      await _insertTask(
        db,
        id: 'turn',
        runId: 'fact-3',
        type: 'super_agent_chat_turn_task',
        status: 'failed',
      );

      await service.markTaskFailed(
        runId: 'fact-3',
        taskId: 'turn',
        taskType: 'super_agent_chat_turn_task',
        error: StateError('bad provider config'),
      );

      final run = await _getRun(db, 'fact-3');
      expect(run.state, 'failed');
      expect(run.stage, 'Needs attention');
      expect(run.message, contains('bad provider config'));
      expect(run.remainingTasks, 0);
      expect(run.completedAt, isNotNull);
    });

    test(
      'new successful attempt resolves old failed activity for same fact',
      () async {
        await service.createForSubmittedInput(
          userId: 'user-a',
          factId: 'fact-retry',
        );
        await _insertTask(
          db,
          id: 'old-turn-failed',
          runId: 'fact-retry',
          type: 'super_agent_chat_turn_task',
          status: 'failed',
        );
        await service.markTaskFailed(
          runId: 'fact-retry',
          taskId: 'old-turn-failed',
          taskType: 'super_agent_chat_turn_task',
          error: StateError('old provider crash'),
        );
        await _setTaskTerminalTimestamp(db, 'old-turn-failed', 1);

        await _insertTask(
          db,
          id: 'new-turn-active',
          runId: 'fact-retry',
          type: 'super_agent_chat_turn_task',
          status: 'processing',
        );
        await service.refreshRunFromTasks('fact-retry');

        var run = await _getRun(db, 'fact-retry');
        expect(run.state, 'running');
        expect(run.stage, 'Running Super Agent');
        expect(run.currentTaskId, 'new-turn-active');

        await _setTaskStatus(db, 'new-turn-active', 'completed');
        await service.markTaskCompleted(
          runId: 'fact-retry',
          taskId: 'new-turn-active',
          taskType: 'super_agent_chat_turn_task',
        );

        run = await _getRun(db, 'fact-retry');
        expect(run.state, 'completed');
        expect(run.stage, 'Completed');
        expect(run.currentTaskId, isNull);
        expect(run.lastError, isNull);
        expect(await service.getLatestVisibleRun(userId: 'user-a'), isNull);
      },
    );

    test(
      'latest failed attempt remains visible when it is newer than success',
      () async {
        await service.createForSubmittedInput(
          userId: 'user-a',
          factId: 'fact-latest-failed',
        );
        await _insertTask(
          db,
          id: 'old-completed-turn',
          runId: 'fact-latest-failed',
          type: 'super_agent_chat_turn_task',
          status: 'completed',
        );
        await _setTaskTerminalTimestamp(db, 'old-completed-turn', 1);
        await _insertTask(
          db,
          id: 'new-failed-turn',
          runId: 'fact-latest-failed',
          type: 'super_agent_chat_turn_task',
          status: 'failed',
        );
        await _setTaskTerminalTimestamp(db, 'new-failed-turn', 2);

        await service.refreshRunFromTasks('fact-latest-failed');

        final run = await _getRun(db, 'fact-latest-failed');
        expect(run.state, 'failed');
        expect(run.stage, 'Needs attention');
        expect(run.currentTaskId, 'new-failed-turn');
      },
    );

    test('marks active runs paused when the OS background window closes',
        () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-4');
      await _insertTask(
        db,
        id: 'turn',
        runId: 'fact-4',
        type: 'super_agent_chat_turn_task',
        status: 'pending',
      );

      await service.markActiveRunsPausedBySystem(
        userId: 'user-a',
        message: 'Background time expired. Memex will continue later.',
      );

      final run = await _getRun(db, 'fact-4');
      expect(run.state, 'paused_by_system');
      expect(run.stage, 'Paused');
      expect(run.message, contains('continue later'));
      expect(run.remainingTasks, 1);

      final visible = await service.getLatestVisibleRun(userId: 'user-a');
      expect(visible?.id, 'fact-4');
      expect(visible?.state, AgentRunState.pausedBySystem);
    });
  });
}

Future<void> _insertTask(
  AppDatabase db, {
  required String id,
  required String runId,
  required String type,
  required String status,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await db.into(db.tasks).insert(
        TasksCompanion.insert(
          id: id,
          type: type,
          payload: const Value('{}'),
          runId: Value(runId),
          status: status,
          createdAt: Value(now),
        ),
      );
}

Future<void> _setTaskStatus(
  AppDatabase db,
  String id,
  String status,
) async {
  await (db.update(db.tasks)..where((task) => task.id.equals(id))).write(
    TasksCompanion(
      status: Value(status),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
    ),
  );
}

Future<void> _setTaskTerminalTimestamp(
  AppDatabase db,
  String id,
  int timestamp,
) async {
  await (db.update(db.tasks)..where((task) => task.id.equals(id))).write(
    TasksCompanion(
      updatedAt: Value(timestamp),
      completedAt: Value(timestamp),
    ),
  );
}

Future<AgentRun> _getRun(AppDatabase db, String id) {
  return (db.select(db.agentRuns)..where((run) => run.id.equals(id)))
      .getSingle();
}
