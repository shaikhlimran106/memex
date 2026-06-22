import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_coordinator.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_queue_drain_scheduler.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/agent_activity/widgets/agent_activity_widget.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'user_id': 'agent-activity-test',
      'language': 'en',
    });
    await UserStorage.initL10n();
    AgentActivityService.setInstance(LocalAgentActivityService.instance);
  });

  tearDown(() {
    resetAgentBackgroundCoordinatorForTesting();
  });

  Widget buildHost({
    bool forceVisible = false,
    TaskActivitySnapshot initialTaskSnapshot =
        const TaskActivitySnapshot.empty(),
    Stream<TaskActivitySnapshot>? taskActivitySnapshotStream,
    AgentRunSnapshot? initialRunSnapshot,
    Stream<AgentRunSnapshot?>? runSnapshotStream,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: AgentActivityWidget(
            forceVisible: forceVisible,
            initialTaskSnapshot: initialTaskSnapshot,
            taskActivitySnapshotStream: taskActivitySnapshotStream ??
                const Stream<TaskActivitySnapshot>.empty(),
            initialRunSnapshot: initialRunSnapshot,
            runSnapshotStream:
                runSnapshotStream ?? const Stream<AgentRunSnapshot?>.empty(),
          ),
        ),
      ),
    );
  }

  testWidgets('shows tappable processing affordance before task activity', (
    tester,
  ) async {
    await tester.pumpWidget(buildHost(forceVisible: true));
    await tester.pump();

    expect(find.text('AI is processing...'), findsOneWidget);

    await tester.tap(find.text('AI is processing...'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Activity Detail'), findsOneWidget);
    expect(find.text('Processing...'), findsOneWidget);

    Navigator.of(tester.element(find.text('Activity Detail'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('updates background task count while detail sheet is open', (
    tester,
  ) async {
    final taskSnapshots = StreamController<TaskActivitySnapshot>.broadcast();
    const initialSnapshot = TaskActivitySnapshot(
      pending: 1,
      processing: 0,
      retrying: 0,
    );

    await tester.pumpWidget(
      buildHost(
        initialTaskSnapshot: initialSnapshot,
        taskActivitySnapshotStream: taskSnapshots.stream,
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    final oneTaskMessage = formatAgentTaskSummary(
      pending: 1,
      processing: 0,
      retrying: 0,
    );
    final twoTaskMessage = formatAgentTaskSummary(
      pending: 1,
      processing: 1,
      retrying: 0,
    );
    expect(find.text(oneTaskMessage), findsOneWidget);

    await tester.tap(find.text('AI is processing...'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text(oneTaskMessage), findsWidgets);

    taskSnapshots.add(
      const TaskActivitySnapshot(pending: 1, processing: 1, retrying: 0),
    );
    await tester.pump();

    expect(find.text(twoTaskMessage), findsWidgets);

    Navigator.of(tester.element(find.text('Activity Detail'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await taskSnapshots.close();
  });

  testWidgets('shows background task count before agent tool messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHost(
        initialTaskSnapshot: const TaskActivitySnapshot(
          pending: 1,
          processing: 0,
          retrying: 0,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('AI is processing...'), findsOneWidget);

    await tester.tap(find.text('AI is processing...'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Running 0, Pending 1, Retry 0'), findsWidgets);

    Navigator.of(tester.element(find.text('Activity Detail'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('shows durable run status after returning from notification', (
    tester,
  ) async {
    final run = AgentRunSnapshot(
      id: 'run-1',
      userId: 'agent-activity-test',
      factId: 'fact-1',
      state: AgentRunState.running,
      stage: 'Running Super Agent',
      message: 'Memex is processing the conversation turn.',
      completedUnits: 20,
      totalUnits: 100,
      remainingTasks: 4,
      currentTaskId: 'task-1',
      currentTaskType: 'super_agent_chat_turn_task',
      updatedAt: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(buildHost(initialRunSnapshot: run));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('AI is processing...'), findsOneWidget);
    expect(find.text('Running 0, Pending 4, Retry 0'), findsOneWidget);

    await tester.tap(find.text('AI is processing...'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Activity Detail'), findsOneWidget);
    expect(find.text('Running 0, Pending 4, Retry 0'), findsWidgets);

    Navigator.of(tester.element(find.text('Activity Detail'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('opens detail sheet from a buffered notification action', (
    tester,
  ) async {
    final platform = _FakePlatform();
    final coordinator = AgentBackgroundCoordinator(
      platform: platform,
      scheduler: _NoopScheduler(),
    );
    setAgentBackgroundCoordinatorForTesting(coordinator);

    await tester.pumpWidget(buildHost());
    emitAgentBackgroundOpenActivityForTesting();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Activity Detail'), findsOneWidget);
    expect(find.text('No agent activity yet'), findsOneWidget);

    Navigator.of(tester.element(find.text('Activity Detail'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    platform.dispose();
  });

  testWidgets(
    'notification action opens detail and renders live background activity',
    (tester) async {
      final platform = _FakePlatform();
      final coordinator = AgentBackgroundCoordinator(
        platform: platform,
        scheduler: _NoopScheduler(),
      );
      setAgentBackgroundCoordinatorForTesting(coordinator);

      await tester.pumpWidget(
        buildHost(
          initialTaskSnapshot: const TaskActivitySnapshot(
            pending: 1,
            processing: 1,
            retrying: 0,
          ),
        ),
      );
      emitAgentBackgroundOpenActivityForTesting();
      await tester.pump(const Duration(milliseconds: 350));

      final taskSummary = formatAgentTaskSummary(
        pending: 1,
        processing: 1,
        retrying: 0,
      );

      expect(find.text('Activity Detail'), findsOneWidget);
      expect(find.text(taskSummary), findsWidgets);

      await AgentActivityService.instance.pushMessage(
        type: AgentActivityType.info,
        title: 'Background notification step',
        content: 'Live notification body',
        agentName: 'Worker Agent',
        agentId: 'worker-agent',
        userId: 'agent-activity-test',
      );
      await tester.pump();

      expect(find.text('Live notification body'), findsOneWidget);
      expect(find.textContaining('Worker Agent'), findsOneWidget);
      expect(find.text(taskSummary), findsWidgets);

      Navigator.of(tester.element(find.text('Activity Detail'))).pop();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      platform.dispose();
    },
  );
}

class _FakePlatform implements AgentBackgroundPlatform {
  String? initialAction;
  final _actions = StreamController<String>.broadcast();

  @override
  bool get isSupported => true;

  @override
  Stream<String> get actionStream => _actions.stream;

  @override
  Future<String?> consumeInitialAction() async => initialAction;

  @override
  Future<void> finishStatus(
    AgentBackgroundStatus status, {
    bool isInBackground = false,
  }) async {}

  @override
  Future<void> stopStatus() async {}

  @override
  Future<void> updateStatus(
    AgentBackgroundStatus status, {
    bool isInBackground = false,
  }) async {}

  void dispose() {
    unawaited(_actions.close());
  }
}

class _NoopScheduler implements AgentQueueDrainScheduler {
  @override
  Future<void> cancel() async {}

  @override
  Future<void> schedule({
    Duration? initialDelay,
    bool expedited = false,
  }) async {}
}
