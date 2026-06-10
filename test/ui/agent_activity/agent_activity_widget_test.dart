import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_coordinator.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_queue_drain_scheduler.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/agent_activity/widgets/agent_activity_widget.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'user_id': 'agent-activity-test'});
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
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: AgentActivityWidget(
            forceVisible: forceVisible,
            initialTaskSnapshot: initialTaskSnapshot,
            taskActivitySnapshotStream:
                taskActivitySnapshotStream ??
                const Stream<TaskActivitySnapshot>.empty(),
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

    final oneTaskMessage = UserStorage.l10n.insightProcessingBacklogMessage(1);
    final twoTaskMessage = UserStorage.l10n.insightProcessingBacklogMessage(2);
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

    expect(find.text('1 background tasks are still processing.'), findsWidgets);

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
