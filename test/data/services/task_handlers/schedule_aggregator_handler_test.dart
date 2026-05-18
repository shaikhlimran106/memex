import 'dart:io';

import 'package:drift/native.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/data/services/schedule_refresh_state_service.dart';
import 'package:memex/data/services/task_handlers/schedule_aggregator_handler.dart';
import 'package:memex/db/app_database.dart';
import 'package:test/test.dart';

void main() {
  group('handleScheduleAggregation', () {
    late Directory tempRoot;
    late AppDatabase db;
    const userId = 'schedule_handler_user';

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'memex_schedule_handler_',
      );
      await FileSystemService.init(tempRoot.path);
      db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);
      await db.searchDao.createFtsTables();
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test(
      'completes empty schedule window as no-op and clears dirty state',
      () async {
        await ScheduleRefreshStateService.instance.markDirty(
          userId: userId,
          reason: 'historical card changed',
          cardIds: const ['2026/01/06.md#ts_1'],
          refreshRequested: true,
        );

        await handleScheduleAggregation(
          userId,
          const {},
          TaskContext(
            taskId: 'schedule_refresh_empty_window',
            taskType: 'schedule_aggregator_task',
          ),
        );

        final latest = await FileSystemService.instance
            .getLatestScheduleAggregation(userId);
        final refreshState = await ScheduleRefreshStateService.instance.read(
          userId,
        );

        expect(latest, isNotNull);
        expect(latest!['no_op'], isTrue);
        expect(latest['no_op_reason'], 'no_temporal_cards_in_window');
        expect(latest['timeline'], isEmpty);
        expect(refreshState.isDirty, isFalse);
        expect(refreshState.cardIds, isEmpty);
        expect(refreshState.lastAggregationId, latest['id']);
        expect(refreshState.refreshRequested, isFalse);
      },
    );
  });
}
