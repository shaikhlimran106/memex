import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileSystemService root switching', () {
    late Directory rootA;
    late Directory rootB;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);
      addTearDown(db.close);
      rootA = await Directory.systemTemp.createTemp('memex_root_a_');
      rootB = await Directory.systemTemp.createTemp('memex_root_b_');
    });

    tearDown(() async {
      await LocalAssetServer.stopServer();
      if (await rootA.exists()) {
        await rootA.delete(recursive: true);
      }
      if (await rootB.exists()) {
        await rootB.delete(recursive: true);
      }
    });

    test('card writes resolve the active root at call time', () async {
      const userA = 'root_switch_a';
      const userB = 'root_switch_b';

      await FileSystemService.init(rootA.path);
      await FileSystemService.instance.safeWriteCardFile(
        userA,
        '2026/06/18.md#ts_1',
        const CardData(
          factId: '2026/06/18.md#ts_1',
          timestamp: 1,
          status: 'completed',
          tags: [],
          uiConfigs: [],
          fact: 'note written into root A',
        ),
      );

      await FileSystemService.init(rootB.path);
      const factId = '2026/06/18.md#ts_1';
      await FileSystemService.instance.safeWriteCardFile(
        userB,
        factId,
        const CardData(
          factId: factId,
          timestamp: 2,
          status: 'completed',
          tags: [],
          uiConfigs: [],
          fact: 'note written into root B',
        ),
      );
      final rootBCard = FileSystemService.instance.getCardPath(userB, factId);

      expect(File(rootBCard).readAsStringSync(), contains('root B'));
      expect(File(rootBCard).existsSync(), isTrue);
      expect(await _rootContains(rootA, 'note written into root B'), isFalse);
    });
  });
}

Future<bool> _rootContains(Directory root, String needle) async {
  await for (final entity in root.list(recursive: true)) {
    if (entity is File &&
        await entity.readAsString().then(
              (content) => content.contains(needle),
              onError: (_) => false,
            )) {
      return true;
    }
  }
  return false;
}
