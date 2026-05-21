import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/user_stats_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/domain/models/user_stats_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const userId = 'stats_user';

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserStorage.saveUser(userId);
    await UserStorage.setLocale(const Locale('en'));
    tempDir = await Directory.systemTemp.createTemp('memex_user_stats_');
    await FileSystemService.init(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'aggregates user-facing stats from facts, cards, and event logs',
    () async {
      final fs = FileSystemService.instance;

      await _writeFactFile(
        fs,
        userId,
        DateTime(2026, 5, 18),
        '## <id:ts_0> 08:00:00 "{}"\n\nWelcome seed card\n'
        '## <id:ts_1> 09:00:00 "{}"\n\nHello world 中文\n'
        '## <id:ts_2> 10:00:00 "{}"\n\nBuy milk\n',
      );
      await _writeFactFile(
        fs,
        userId,
        DateTime(2026, 5, 19),
        '## <id:ts_1> 09:00:00 "{}"\n\nAnother note\n',
      );

      await fs.safeWriteCardFile(
        userId,
        '2026/05/18.md#ts_0',
        CardData(
          factId: '2026/05/18.md#ts_0',
          timestamp: DateTime(2026, 5, 18, 8).millisecondsSinceEpoch ~/ 1000,
          status: 'completed',
          tags: const ['seed'],
          uiConfigs: const [
            UiConfig(
              templateId: 'classic_card',
              data: {'title': 'Welcome seed'},
            ),
          ],
        ),
      );
      await fs.safeWriteCardFile(
        userId,
        '2026/05/18.md#ts_1',
        CardData(
          factId: '2026/05/18.md#ts_1',
          timestamp: DateTime(2026, 5, 18, 9).millisecondsSinceEpoch ~/ 1000,
          status: 'completed',
          tags: const ['work'],
          uiConfigs: const [
            UiConfig(
              templateId: 'classic_card',
              data: {'title': 'Morning note'},
            ),
          ],
        ),
      );
      await fs.safeWriteCardFile(
        userId,
        '2026/05/18.md#ts_2',
        CardData(
          factId: '2026/05/18.md#ts_2',
          timestamp: DateTime(2026, 5, 18, 10).millisecondsSinceEpoch ~/ 1000,
          status: 'processing',
          tags: const [],
          uiConfigs: const [
            UiConfig(templateId: 'classic_card', data: {'title': 'Pending'}),
          ],
        ),
      );
      await fs.safeWriteCardFile(
        userId,
        '2026/05/19.md#ts_1',
        CardData(
          factId: '2026/05/19.md#ts_1',
          timestamp: DateTime(2026, 5, 19, 9).millisecondsSinceEpoch ~/ 1000,
          status: 'completed',
          tags: const ['home'],
          uiConfigs: const [
            UiConfig(
              templateId: 'task',
              data: {'title': 'Clean desk', 'is_completed': true},
            ),
          ],
        ),
      );

      await _writeEvents(fs, userId, [
        _event(
          type: 'user_input',
          time: DateTime(2026, 5, 18, 9),
          metadata: {
            'fact_id': '2026/05/18.md#ts_1',
            'has_text': true,
            'has_images': false,
            'has_audio': false,
          },
        ),
        _event(
          type: 'user_input',
          time: DateTime(2026, 5, 18, 10),
          metadata: {
            'fact_id': '2026/05/18.md#ts_2',
            'has_text': false,
            'has_images': true,
            'has_audio': false,
          },
        ),
        _event(
          type: 'user_input',
          time: DateTime(2026, 5, 19, 9),
          metadata: {
            'fact_id': '2026/05/19.md#ts_1',
            'has_text': false,
            'has_images': false,
            'has_audio': true,
          },
        ),
        _event(
          type: 'file_modified',
          time: DateTime(2026, 5, 18, 12),
          filePath: 'PKM/Areas/work.md',
        ),
        _event(
          type: 'file_modified',
          time: DateTime(2026, 5, 18, 13),
          filePath: 'PKM/Areas/work.md',
        ),
        _event(
          type: 'file_created',
          time: DateTime(2026, 5, 19, 12),
          filePath: 'PKM/Projects/app.md',
        ),
        _event(
          type: 'file_created',
          time: DateTime(2026, 5, 19, 16),
          filePath: 'KnowledgeInsights/Cards/weekly.yaml',
          metadata: {'title': 'Weekly pattern'},
        ),
        _event(
          type: 'todo_completed',
          time: DateTime(2026, 5, 20, 8),
          metadata: {'title': 'Clean desk'},
        ),
      ]);

      final snapshot = await UserStatsService().fetchSnapshot(
        userId: userId,
        range: UserStatsDateRange(
          start: DateTime(2026, 5, 14),
          end: DateTime(2026, 5, 20),
        ),
      );

      expect(snapshot.summary.totalInputs, 3);
      expect(snapshot.summary.totalWords, 8);
      expect(snapshot.summary.totalCards, 2);
      expect(snapshot.summary.totalKnowledgeUnits, 2);
      expect(snapshot.summary.totalInsights, 1);
      expect(snapshot.summary.totalCompletedTodos, 1);
      expect(snapshot.summary.activeDays, 3);
      expect(snapshot.summary.currentStreakDays, 3);
      expect(snapshot.sourceBreakdown.textInputs, 1);
      expect(snapshot.sourceBreakdown.imageInputs, 1);
      expect(snapshot.sourceBreakdown.audioInputs, 1);
      expect(
        snapshot.topTags.map((tag) => tag.label),
        containsAll(['work', 'home']),
      );

      final may18 = snapshot.pointFor(DateTime(2026, 5, 18))!;
      expect(may18.inputs, 2);
      expect(may18.cards, 1);
      expect(may18.knowledgeUnits, 1);

      final may19Detail = snapshot.dayDetails['2026-05-19']!;
      expect(may19Detail.insightTitles, contains('Weekly pattern'));
      expect(may19Detail.knowledgePaths, contains('PKM/Projects/app.md'));
    },
  );

  test(
    'falls back to local files when activity events are unavailable',
    () async {
      final fs = FileSystemService.instance;
      final pkmFile = File(p.join(fs.getPkmPath(userId), 'Areas', 'health.md'));
      await pkmFile.parent.create(recursive: true);
      await pkmFile.writeAsString('# Health\n');
      await pkmFile.setLastModified(DateTime(2026, 5, 18, 12));

      await fs.writeKnowledgeInsightCard(userId, 'health_week', {
        'id': 'health_week',
        'title': 'Health week',
        'template_id': 'summary_card_v1',
        'updated_at': DateTime(2026, 5, 18, 10).toIso8601String(),
      });

      await fs.safeWriteCardFile(
        userId,
        '2026/05/18.md#ts_1',
        CardData(
          factId: '2026/05/18.md#ts_1',
          timestamp: DateTime(2026, 5, 18, 9).millisecondsSinceEpoch ~/ 1000,
          status: 'completed',
          tags: const [],
          uiConfigs: const [
            UiConfig(
              templateId: 'task',
              data: {'title': 'Drink water', 'is_completed': true},
            ),
          ],
        ),
      );

      final snapshot = await UserStatsService().fetchSnapshot(
        userId: userId,
        range: UserStatsDateRange(
          start: DateTime(2026, 5, 18),
          end: DateTime(2026, 5, 18),
        ),
      );

      expect(snapshot.summary.totalKnowledgeUnits, 1);
      expect(snapshot.summary.totalInsights, 1);
      expect(snapshot.summary.totalCompletedTodos, 1);
      expect(
        snapshot.dayDetails['2026-05-18']!.knowledgePaths,
        contains('PKM/Areas/health.md'),
      );
      expect(
        snapshot.dayDetails['2026-05-18']!.insightTitles,
        contains('Health week'),
      );
    },
  );
}

Map<String, dynamic> _event({
  required String type,
  required DateTime time,
  String? filePath,
  Map<String, dynamic>? metadata,
}) {
  return {
    'event_type': type,
    'description': type,
    'event_time': time.toIso8601String(),
    'event_time_unix_seconds': time.millisecondsSinceEpoch ~/ 1000,
    'user_id': userId,
    if (filePath != null) 'file_path': filePath,
    if (metadata != null) 'metadata': metadata,
  };
}

Future<void> _writeEvents(
  FileSystemService fs,
  String userId,
  List<Map<String, dynamic>> events,
) async {
  final byDate = <String, List<Map<String, dynamic>>>{};
  for (final event in events) {
    final date = DateTime.parse(event['event_time'] as String);
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    byDate.putIfAbsent(key, () => []).add(event);
  }

  for (final entry in byDate.entries) {
    final date = DateTime.parse(entry.key);
    final file = File(fs.eventLogService.getEventLogPath(userId, date));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${entry.value.map(jsonEncode).join('\n')}\n',
      mode: FileMode.append,
    );
  }
}

Future<void> _writeFactFile(
  FileSystemService fs,
  String userId,
  DateTime date,
  String content,
) async {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final file = File(p.join(fs.getFactsPath(userId), year, month, '$day.md'));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
