import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/repositories/submit_input.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileSystemService root switching', () {
    late Directory rootA;
    late Directory rootB;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
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

    test('submitInput resolves the active root at call time', () async {
      const userA = 'root_switch_a';
      const userB = 'root_switch_b';

      await FileSystemService.init(rootA.path);
      await submitInput(userA, [
        {'type': 'text', 'text': 'note written into root A'},
      ]);

      await FileSystemService.init(rootB.path);
      final result = await submitInput(userB, [
        {'type': 'text', 'text': 'note written into root B'},
      ]);

      final factId = result['fact_id'] as String;
      final factPath = factId.split('#').first;
      final rootBFact = p.join(
        FileSystemService.instance.getFactsPath(userB),
        factPath,
      );
      final rootBCard = FileSystemService.instance.getCardPath(userB, factId);

      expect(File(rootBFact).readAsStringSync(), contains('root B'));
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
