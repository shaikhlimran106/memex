import 'package:flutter_test/flutter_test.dart';
import 'package:memex/domain/models/reprocess_cards_options.dart';
import 'package:memex/ui/settings/view_models/debug_settings_viewmodel.dart';
import 'package:memex/ui/settings/widgets/reprocess_cards_dialog.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
  });

  test('createReprocessCardsTask enqueues reprocess cards task', () async {
    await UserStorage.saveUser('debug-viewmodel-user');
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    final created = await viewModel.createReprocessCardsTask(
      const ReprocessCardsDebugOptions(limit: 5, reanalyzeAssets: true),
    );

    expect(created, isTrue);
    expect(viewModel.isReprocessingCards, isFalse);
    expect(dataController.enqueuedTasks, hasLength(1));

    final task = dataController.enqueuedTasks.single;
    expect(task.taskType, 'reprocess_cards_task');
    expect(task.bizId, startsWith('reprocess_cards_'));
    expect(task.payload['limit'], 5);
    expect(task.payload['reanalyze_assets'], isTrue);
    expect(
      task.payload[ReprocessCardsPayloadKeys.downstreamMode],
      ReprocessCardsDownstreamMode.cardOnly.payloadValue,
    );
  });

  test('createReprocessCardsTask requires a user and resets loading', () async {
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    await expectLater(
      viewModel.createReprocessCardsTask(const ReprocessCardsDebugOptions()),
      throwsA(isA<DebugSettingsUserNotFoundException>()),
    );

    expect(viewModel.isReprocessingCards, isFalse);
    expect(dataController.enqueuedTasks, isEmpty);
  });

  test('date range task options format payload consistently', () {
    final payload = DebugDateRangeTaskOptions(
      dateFrom: DateTime(2026, 6, 1),
      dateTo: DateTime(2026, 6, 16),
      limit: 25,
    ).toTaskPayload();

    expect(payload['date_from'], '2026-06-01');
    expect(payload['date_to'], '2026-06-16');
    expect(payload['limit'], 25);
    expect(
      DebugDateRangeTaskOptions.formatDate(DateTime(2026, 1, 9)),
      '2026-01-09',
    );
  });

  test('clearToken clears user and resets router state', () async {
    await UserStorage.saveUser('debug-viewmodel-user');
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    await viewModel.clearToken();

    expect(await UserStorage.getUserId(), isNull);
    expect(dataController.resetForLogoutCount, 1);
  });

  test('clearData requires user and clears cached agent data', () async {
    await UserStorage.saveUser('debug-viewmodel-user');
    final staleCache = AgentCacheData(
      responseId: 'stale',
      systemPromptHash: 1,
      toolsHash: 2,
    );
    await UserStorage.saveCachedAgentData('pkm', staleCache);
    await UserStorage.saveCachedAgentData('card', staleCache);
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    final cleared = await viewModel.clearData();

    expect(cleared, isTrue);
    expect(viewModel.isClearingData, isFalse);
    expect(dataController.clearDataCount, 1);
    expect(await UserStorage.getCachedAgentData('pkm'), isNull);
    expect(await UserStorage.getCachedAgentData('card'), isNull);
  });

  test('clearFailedAgentContexts returns cleared count', () async {
    final dataController = _RecordingDebugSettingsDataController(
      clearedFailedAgentContexts: 3,
    );
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    final clearedCount = await viewModel.clearFailedAgentContexts();

    expect(clearedCount, 3);
    expect(viewModel.isClearingFailedAgentContexts, isFalse);
    expect(dataController.clearFailedAgentContextsCount, 1);
  });

  test('creates comments and knowledge base reprocess tasks', () async {
    await UserStorage.saveUser('debug-viewmodel-user');
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);
    final options = DebugDateRangeTaskOptions(
      dateFrom: DateTime(2026, 6, 1),
      dateTo: DateTime(2026, 6, 16),
    );

    expect(await viewModel.createReprocessCommentsTask(options), isTrue);
    expect(await viewModel.createReprocessKnowledgeBaseTask(options), isTrue);

    expect(dataController.enqueuedTasks, hasLength(2));
    expect(
      dataController.enqueuedTasks[0].taskType,
      'reprocess_comments_task',
    );
    expect(
      dataController.enqueuedTasks[0].bizId,
      startsWith('reprocess_comments_'),
    );
    expect(
      dataController.enqueuedTasks[1].taskType,
      'reprocess_knowledge_base_task',
    );
    expect(
      dataController.enqueuedTasks[1].bizId,
      startsWith('reprocess_knowledge_base_'),
    );
    expect(dataController.enqueuedTasks[1].payload['date_to'], '2026-06-16');
  });

  test('rebuildSearchIndex delegates to data controller', () async {
    final dataController = _RecordingDebugSettingsDataController();
    final viewModel = DebugSettingsViewModel(dataController: dataController);

    final rebuilt = await viewModel.rebuildSearchIndex();

    expect(rebuilt, isTrue);
    expect(viewModel.isRebuildingSearchIndex, isFalse);
    expect(dataController.rebuildAllFtsIndexesCount, 1);
  });
}

class _QueuedDebugTask {
  const _QueuedDebugTask({
    required this.taskType,
    required this.payload,
    this.bizId,
  });

  final String taskType;
  final Map<String, dynamic> payload;
  final String? bizId;
}

class _RecordingDebugSettingsDataController
    implements DebugSettingsDataController {
  _RecordingDebugSettingsDataController({
    this.clearedFailedAgentContexts = 0,
  });

  final enqueuedTasks = <_QueuedDebugTask>[];
  final int clearedFailedAgentContexts;
  int clearDataCount = 0;
  int clearFailedAgentContextsCount = 0;
  int rebuildAllFtsIndexesCount = 0;
  int resetForLogoutCount = 0;

  @override
  Future<void> enqueueTask({
    required String taskType,
    required Map<String, dynamic> payload,
    String? bizId,
  }) async {
    enqueuedTasks.add(
      _QueuedDebugTask(
        taskType: taskType,
        payload: Map<String, dynamic>.from(payload),
        bizId: bizId,
      ),
    );
  }

  @override
  Future<void> clearData() async {
    clearDataCount++;
  }

  @override
  Future<int> clearFailedAgentConversationContexts() async {
    clearFailedAgentContextsCount++;
    return clearedFailedAgentContexts;
  }

  @override
  Future<void> rebuildAllFtsIndexes() async {
    rebuildAllFtsIndexesCount++;
  }

  @override
  void resetForLogout() {
    resetForLogoutCount++;
  }
}
