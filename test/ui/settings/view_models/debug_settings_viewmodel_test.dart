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
  final enqueuedTasks = <_QueuedDebugTask>[];

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
  Future<void> clearData() async {}

  @override
  Future<int> clearFailedAgentConversationContexts() async => 0;

  @override
  Future<void> rebuildAllFtsIndexes() async {}

  @override
  void resetForLogout() {}
}
