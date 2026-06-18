import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/repositories/migrate_cards_fact_assets.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:path/path.dart' as p;

void main() {
  group('migrateCardsToFactAssets', () {
    late AppDatabase db;
    late Directory tempRoot;
    late String userId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);

      tempRoot = await Directory.systemTemp.createTemp('memex_migrate_cards_');
      await FileSystemService.init(tempRoot.path);
      userId = 'migrate_${DateTime.now().microsecondsSinceEpoch}';
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
      await db.close();
    });

    test('backfills legacy fact text, assets, and created_at', () async {
      final fs = FileSystemService.instance;
      final date = DateTime(2026, 5, 18);
      const factId = '2026/05/18.md#ts_1';

      await fs.appendToDailyFactFile(
        userId,
        date,
        '## <id:ts_1> 09:08:07\n\n'
        '早餐吃了豆浆油条。\n'
        '![image](fs://breakfast.jpg)',
      );
      await fs.safeWriteCardFile(
        userId,
        factId,
        const CardData(
          factId: factId,
          timestamp: 0,
          status: 'completed',
          tags: [],
          uiConfigs: [],
        ),
      );

      await migrateCardsToFactAssets(userId);

      final card = await fs.readCardFile(userId, factId);
      expect(card, isNotNull);
      expect(card!.fact, '早餐吃了豆浆油条。');
      expect(card.assets, ['![image](fs://breakfast.jpg)']);
      expect(
        card.createdAt,
        DateTime(2026, 5, 18, 9, 8, 7).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('v2 backfills missing created_at without clobbering migrated content',
        () async {
      final fs = FileSystemService.instance;
      final date = DateTime(2026, 5, 18);
      const factId = '2026/05/18.md#ts_2';

      await fs.appendToDailyFactFile(
        userId,
        date,
        '## <id:ts_2> 10:11:12\n\n'
        'legacy fact text [audio](fs://voice.m4a)',
      );
      await fs.safeWriteCardFile(
        userId,
        factId,
        const CardData(
          factId: factId,
          timestamp: 0,
          status: 'completed',
          tags: [],
          uiConfigs: [],
          fact: 'already migrated fact',
          assets: ['![image](fs://already.jpg)'],
        ),
      );
      await _writeMigrationState(userId, {'cards_fact_assets_v1': true});

      await migrateCardsToFactAssets(userId);

      final card = await fs.readCardFile(userId, factId);
      expect(card, isNotNull);
      expect(card!.fact, 'already migrated fact');
      expect(card.assets, ['![image](fs://already.jpg)']);
      expect(
        card.createdAt,
        DateTime(2026, 5, 18, 10, 11, 12).millisecondsSinceEpoch ~/ 1000,
      );
    });
  });
}

Future<void> _writeMigrationState(
    String userId, Map<String, dynamic> state) async {
  final systemPath = FileSystemService.instance.getSystemPath(userId);
  await Directory(systemPath).create(recursive: true);
  final file = File(p.join(systemPath, 'migration_state.json'));
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(state));
}
