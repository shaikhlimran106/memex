import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/timeline_diagnostics/timeline_diagnostics_skill.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('TimelineDiagnosticsSkill', () {
    late Directory tempDir;
    const userId = 'test_user';
    const cardId = '2026/06/10.md#ts_1';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.saveUser(userId);
      tempDir = await Directory.systemTemp.createTemp('memex_timeline_diag_');
      await FileSystemService.init(tempDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('registers diagnostic tools', () {
      final skill = TimelineDiagnosticsSkill();

      expect(skill.name, 'timeline_diagnostics');
      expect(
        skill.tools?.map((tool) => tool.name),
        containsAll([
          'list_recent_timeline_cards',
          'inspect_timeline_card',
          'inspect_timeline_card_assets',
          'describe_timeline_render_path',
          'retry_failed_timeline_card',
        ]),
      );
    });

    test('extracts fs refs with asset kinds', () {
      final refs = TimelineDiagnosticsSkill.extractFsRefsForTesting(
        '![image](fs://photo.jpg) [audio](fs://voice.m4a) "fs://note.txt"',
      );

      expect(refs, hasLength(3));
      expect(refs[0]['filename'], 'photo.jpg');
      expect(refs[0]['kind'], 'image');
      expect(refs[1]['filename'], 'voice.m4a');
      expect(refs[1]['kind'], 'audio');
      expect(refs[2]['filename'], 'note.txt');
      expect(refs[2]['kind'], 'unknown');
    });

    test('warns when fact image is not referenced by normal ui configs',
        () async {
      await _writeFactAndAsset(userId: userId);
      await _writeCard(
        userId: userId,
        cardId: cardId,
        uiConfigs: const [
          UiConfig(
            templateId: 'classic_card',
            data: {'content': '今天拍了两张图'},
          ),
        ],
      );

      final result = await TimelineDiagnosticsSkill.inspectTimelineCardForUser(
        userId: userId,
        cardId: cardId,
      );

      expect(result['card_found'], isTrue);
      expect(result['fact_found'], isTrue);
      expect(result['can_verify_current_screen'], isFalse);
      expect(
        result['warnings'] as List,
        contains(
          contains(
              'Fact has image assets, but normal ui_configs do not reference'),
        ),
      );

      final renderPath = result['render_path'] as Map<String, dynamic>;
      expect(renderPath['fact_has_image_assets'], isTrue);
      expect(renderPath['normal_mode_has_image_refs_in_ui_config'], isFalse);
    });

    test('reports existing assets and ui config image references', () async {
      await _writeFactAndAsset(userId: userId);
      await _writeCard(
        userId: userId,
        cardId: cardId,
        uiConfigs: const [
          UiConfig(
            templateId: 'classic_card',
            data: {
              'content': '今天拍了两张图',
              'images': ['fs://photo.jpg'],
            },
          ),
        ],
      );

      final result =
          await TimelineDiagnosticsSkill.inspectTimelineCardAssetsForUser(
        userId: userId,
        cardId: cardId,
      );

      expect(result['asset_count'], 2);
      expect(result['missing_asset_count'], 0);

      final renderPath =
          await TimelineDiagnosticsSkill.describeTimelineRenderPathForUser(
        userId: userId,
        cardId: cardId,
      );
      final render = renderPath['render_path'] as Map<String, dynamic>;
      expect(render['normal_mode_has_image_refs_in_ui_config'], isTrue);
    });

    test('returns structured not found result for missing card', () async {
      final result = await TimelineDiagnosticsSkill.inspectTimelineCardForUser(
        userId: userId,
        cardId: '2026/06/10.md#ts_9',
      );

      expect(result['kind'], 'timeline_card_not_found');
      expect(result['card_found'], isFalse);
    });
  });
}

Future<void> _writeFactAndAsset({required String userId}) async {
  final fs = FileSystemService.instance;
  await fs.appendToDailyFactFile(
    userId,
    DateTime(2026, 6, 10),
    '## <id:ts_1> 09:00:00 "{}"\n\n今天拍了两张图\n![image](fs://photo.jpg)\n',
  );

  final assetsDir = Directory(fs.getAssetsPath(userId));
  await assetsDir.create(recursive: true);
  final imagePath = path.join(assetsDir.path, 'photo.jpg');
  await File(imagePath).writeAsBytes([0, 1, 2, 3]);
  await File('$imagePath.analysis.txt').writeAsString('A test image.');
}

Future<void> _writeCard({
  required String userId,
  required String cardId,
  required List<UiConfig> uiConfigs,
}) async {
  final timestamp = DateTime(2026, 6, 10, 9).millisecondsSinceEpoch ~/ 1000;
  await FileSystemService.instance.safeWriteCardFile(
    userId,
    cardId,
    CardData(
      factId: cardId,
      timestamp: timestamp,
      status: 'completed',
      tags: const ['Visual'],
      title: '测试图片',
      uiConfigs: uiConfigs,
    ),
  );
}
