import 'package:drift/drift.dart' hide isNotNull;
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
    test('tracks a coarse card generation run through task boundaries',
        () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-1');
      await _insertTask(
        db,
        id: 'analyze',
        runId: 'fact-1',
        type: 'handle_analyze_assets',
        status: 'pending',
      );
      await _insertTask(
        db,
        id: 'card',
        runId: 'fact-1',
        type: 'card_agent_task',
        status: 'pending',
      );

      await service.refreshRunFromTasks('fact-1');
      var run = await _getRun(db, 'fact-1');
      expect(run.state, 'queued');
      expect(run.stage, 'Queued');
      expect(run.remainingTasks, 2);

      await _setTaskStatus(db, 'analyze', 'processing');
      await service.markTaskStarted(
        runId: 'fact-1',
        taskId: 'analyze',
        taskType: 'handle_analyze_assets',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'running');
      expect(run.stage, 'Analyzing media');
      expect(run.completedUnits, 10);

      await _setTaskStatus(db, 'analyze', 'completed');
      await service.markTaskCompleted(
        runId: 'fact-1',
        taskId: 'analyze',
        taskType: 'handle_analyze_assets',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'queued');
      expect(run.stage, 'Queued');
      expect(run.completedUnits, 25);
      expect(run.remainingTasks, 1);

      await _setTaskStatus(db, 'card', 'processing');
      await service.markTaskStarted(
        runId: 'fact-1',
        taskId: 'card',
        taskType: 'card_agent_task',
      );
      run = await _getRun(db, 'fact-1');
      expect(run.state, 'running');
      expect(run.stage, 'Generating card');
      expect(run.completedUnits, 30);

      await _setTaskStatus(db, 'card', 'completed');
      await service.markTaskCompleted(
        runId: 'fact-1',
        taskId: 'card',
        taskType: 'card_agent_task',
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
        id: 'card',
        runId: 'fact-2',
        type: 'card_agent_task',
        status: 'retrying',
      );

      await service.markTaskRetrying(
        runId: 'fact-2',
        taskId: 'card',
        taskType: 'card_agent_task',
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
        id: 'card',
        runId: 'fact-3',
        type: 'card_agent_task',
        status: 'failed',
      );

      await service.markTaskFailed(
        runId: 'fact-3',
        taskId: 'card',
        taskType: 'card_agent_task',
        error: StateError('bad provider config'),
      );

      final run = await _getRun(db, 'fact-3');
      expect(run.state, 'failed');
      expect(run.stage, 'Needs attention');
      expect(run.message, contains('bad provider config'));
      expect(run.remainingTasks, 0);
      expect(run.completedAt, isNotNull);
    });

    test('marks active runs paused when the OS background window closes',
        () async {
      await service.createForSubmittedInput(userId: 'user-a', factId: 'fact-4');
      await _insertTask(
        db,
        id: 'pkm',
        runId: 'fact-4',
        type: 'pkm_agent_task',
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

Future<AgentRun> _getRun(AppDatabase db, String id) {
  return (db.select(db.agentRuns)..where((run) => run.id.equals(id)))
      .getSingle();
}
