import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_queue_background_worker.dart';
import 'package:memex/data/services/agent_queue_drain_scheduler.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentQueueBackgroundWorker', () {
    late AppDatabase db;
    late LocalTaskExecutor executor;
    late _FakeDrainScheduler scheduler;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'user_id': 'worker-user',
        'language': 'en',
      });
      await UserStorage.initL10n();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);
      executor = LocalTaskExecutor.forTesting();
      scheduler = _FakeDrainScheduler();
    });

    tearDown(() async {
      executor.stop();
      await db.close();
    });

    test('recognizes both WorkManager task name and unique work name', () {
      expect(
        AgentQueueBackgroundWorker.isAgentQueueDrainTask(
          WorkmanagerAgentQueueDrainScheduler.taskName,
        ),
        isTrue,
      );
      expect(
        AgentQueueBackgroundWorker.isAgentQueueDrainTask(
          WorkmanagerAgentQueueDrainScheduler.uniqueName,
        ),
        isTrue,
      );
      expect(
        AgentQueueBackgroundWorker.isAgentQueueDrainTask(
          'workmanager.background.task',
        ),
        isFalse,
      );
    });

    test('clamps immediate retry delay to at least thirty seconds', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      expect(
        AgentQueueBackgroundWorker.clampNextDelay(now - 120),
        const Duration(seconds: 30),
      );
      expect(
        AgentQueueBackgroundWorker.clampNextDelay(now + 10),
        const Duration(seconds: 30),
      );
    });

    test('keeps future retry delay when it is longer than the clamp', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      expect(
        AgentQueueBackgroundWorker.clampNextDelay(now + 600),
        const Duration(seconds: 600),
      );
    });

    test('does not initialize task queue when no user is active', () async {
      SharedPreferences.setMockInitialValues({});
      var initialized = false;
      final platform = _FakeBackgroundPlatform();

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {
          initialized = true;
        },
        executor: executor,
        scheduler: scheduler,
        backgroundPlatform: platform,
      );

      expect(completed, isTrue);
      expect(initialized, isFalse);
      expect(scheduler.scheduleCalls, 0);
      expect(platform.stopCalls, 1);
    });

    test('retries a transient database lock before draining queue', () async {
      var attempts = 0;
      final platform = _FakeBackgroundPlatform();

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {
          attempts++;
          if (attempts == 1) {
            throw Exception('SqliteException(5): database is locked (code 5)');
          }
        },
        executor: executor,
        scheduler: scheduler,
        backgroundPlatform: platform,
        databaseRetryDelay: Duration.zero,
      );

      expect(completed, isTrue);
      expect(attempts, 2);
      expect(scheduler.scheduleCalls, 0);
      expect(platform.stopCalls, 1);
    });

    test('does not retry non-database initialization failures', () async {
      var attempts = 0;

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {
          attempts++;
          throw StateError('bad background setup');
        },
        executor: executor,
        scheduler: scheduler,
        databaseRetryDelay: Duration.zero,
      );

      expect(completed, isFalse);
      expect(attempts, 1);
    });

    test('reschedules when only future retrying tasks remain', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.into(db.tasks).insert(
            TasksCompanion.insert(
              id: 'future-retry',
              type: 'unknown_task',
              payload: const Value('{}'),
              status: 'retrying',
              createdAt: Value(now),
              scheduledAt: Value(now + 600),
            ),
          );
      final platform = _FakeBackgroundPlatform();

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {},
        executor: executor,
        scheduler: scheduler,
        backgroundPlatform: platform,
        databaseRetryDelay: Duration.zero,
      );

      expect(completed, isTrue);
      expect(scheduler.scheduleCalls, 1);
      expect(scheduler.expeditedValues.single, isFalse);
      expect(
        scheduler.initialDelays.single!.inSeconds,
        inInclusiveRange(590, 600),
      );
      expect(platform.updates.single.state, AgentBackgroundRunState.active);
      expect(platform.updateBackgroundFlags.single, isTrue);
      expect(platform.stopCalls, 0);
    });

    test('marks durable run paused when background slice ends with work left',
        () async {
      await AgentRunService.instance.createForSubmittedInput(
        userId: 'worker-user',
        factId: 'fact-paused',
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.into(db.tasks).insert(
            TasksCompanion.insert(
              id: 'future-retry',
              type: 'card_agent_task',
              payload: const Value('{}'),
              runId: const Value('fact-paused'),
              status: 'retrying',
              createdAt: Value(now),
              scheduledAt: Value(now + 600),
            ),
          );
      final platform = _FakeBackgroundPlatform();

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {},
        executor: executor,
        scheduler: scheduler,
        backgroundPlatform: platform,
        databaseRetryDelay: Duration.zero,
      );

      final run = await (db.select(db.agentRuns)
            ..where((row) => row.id.equals('fact-paused')))
          .getSingle();

      expect(completed, isTrue);
      expect(run.state, 'paused_by_system');
      expect(run.message, UserStorage.l10n.agentBackgroundQueuedDetail);
      expect(platform.updates.single.state, AgentBackgroundRunState.paused);
      expect(platform.updates.single.runId, 'fact-paused');
      expect(scheduler.scheduleCalls, 1);
    });

    test('drains handlers that publish agent activity after init', () async {
      executor.registerHandler('activity_task', (
        userId,
        payload,
        context,
      ) async {
        await AgentActivityService.instance.pushMessage(
          type: AgentActivityType.info,
          title: 'Background activity',
          content: 'worker drain',
          agentName: 'Worker Agent',
          agentId: 'worker-agent',
          userId: userId,
        );
      });
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.into(db.tasks).insert(
            TasksCompanion.insert(
              id: 'activity-task',
              type: 'activity_task',
              payload: const Value('{}'),
              status: 'pending',
              createdAt: Value(now),
            ),
          );
      final platform = _FakeBackgroundPlatform();

      final completed = await AgentQueueBackgroundWorker.run(
        initializeTaskQueue: (_) async {
          AgentActivityService.setInstance(LocalAgentActivityService.instance);
        },
        executor: executor,
        scheduler: scheduler,
        backgroundPlatform: platform,
        databaseRetryDelay: Duration.zero,
      );

      final task = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals('activity-task')))
          .getSingle();
      final messages = await LocalAgentActivityService.instance.getHistory(
        limit: 1,
      );

      expect(completed, isTrue);
      expect(task.status, 'completed');
      expect(messages.single.title, 'Background activity');
      expect(scheduler.scheduleCalls, 0);
      expect(platform.stopCalls, 1);
    });
  });
}

class _FakeBackgroundPlatform implements AgentBackgroundPlatform {
  final updates = <AgentBackgroundStatus>[];
  final updateBackgroundFlags = <bool>[];
  var finishCalls = 0;
  var stopCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Stream<String> get actionStream => const Stream<String>.empty();

  @override
  Future<String?> consumeInitialAction() async => null;

  @override
  Future<void> finishStatus(
    AgentBackgroundStatus status, {
    bool isInBackground = false,
  }) async {
    finishCalls++;
  }

  @override
  Future<void> stopStatus() async {
    stopCalls++;
  }

  @override
  Future<void> updateStatus(
    AgentBackgroundStatus status, {
    bool isInBackground = false,
  }) async {
    updates.add(status);
    updateBackgroundFlags.add(isInBackground);
  }
}

class _FakeDrainScheduler implements AgentQueueDrainScheduler {
  final initialDelays = <Duration?>[];
  final expeditedValues = <bool>[];
  var cancelCalls = 0;

  int get scheduleCalls => initialDelays.length;

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> schedule({
    Duration? initialDelay,
    bool expedited = false,
  }) async {
    initialDelays.add(initialDelay);
    expeditedValues.add(expedited);
  }
}
