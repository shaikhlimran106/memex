import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/timeline_diagnostics/timeline_diagnostics_skill.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/time_context.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _recordDateTime = DateTime(2026, 6, 10, 9);
final _recordTimestamp = _recordDateTime.millisecondsSinceEpoch ~/ 1000;

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

    test('registers focused diagnostic tools', () {
      final skill = TimelineDiagnosticsSkill();

      expect(skill.name, 'timeline_diagnostics');
      expect(
        skill.tools?.map((tool) => tool.name),
        [
          'search_timeline_cards',
          'inspect_timeline_card',
        ],
      );
    });

    test('search without query returns recent cards with local time', () async {
      await _writeFactAndAsset(userId: userId);
      await _writeCard(userId: userId, cardId: cardId);

      final result = await TimelineDiagnosticsSkill.searchTimelineCards(
        query: null,
        limit: 50,
        userId: userId,
      );

      expect(result, contains('Recent timeline cards:'));
      expect(result, contains(cardId));
      expect(
        result,
        contains(
          formatLocalDateTimeWithZone(
              dateTimeFromUnixSeconds(_recordTimestamp)),
        ),
      );
      expect(result, contains('测试图片'));
    });

    test(
        'inspect returns original input context and current card data without comments',
        () async {
      await _writeFactAndAsset(userId: userId);
      await _writeCard(userId: userId, cardId: cardId);

      final result = await TimelineDiagnosticsSkill.inspectTimelineCardForUser(
        userId: userId,
        cardId: cardId,
      );

      expect(result, contains('Original input context:'));
      expect(
        result,
        contains(
          'Published time: ${formatLocalDateTimeWithZone(_recordDateTime)}',
        ),
      );
      expect(result, contains('Original user input (fact):'));
      expect(result, contains('今天拍了两张图'));
      expect(result, contains('Associated media files:'));
      expect(result, contains('- ![image](fs://photo.jpg)'));
      expect(result, contains('Current CardData:'));
      expect(result, contains('fact_id: $cardId'));
      expect(result, contains('status: failed'));
      expect(result, contains('tags: Visual'));
      expect(result, contains('title: 测试图片'));
      expect(result, contains('address: Beijing · Chaoyang Park'));
      expect(result, contains('user_fixed_timestamp: $_recordTimestamp'));
      expect(result, contains('user_fixed_address: Shanghai · Jing’an'));
      expect(result, contains('failure_reason: LLM timeout'));
      expect(result, isNot(contains('comments')));
      expect(result, contains('summary: A useful visual memory.'));
      expect(result, contains('template_id: snapshot'));
      expect(result, contains('image_url: fs://photo.jpg'));

      final createdAtLocal =
          await TimelineDiagnosticsSkill.createdAtLocalForCardForTesting(
        userId: userId,
        cardId: cardId,
      );
      expect(
        createdAtLocal,
        formatLocalDateTimeWithZone(dateTimeFromUnixSeconds(_recordTimestamp)),
      );
    });

    test('returns structured not found result for missing card', () async {
      final result = await TimelineDiagnosticsSkill.inspectTimelineCardForUser(
        userId: userId,
        cardId: '2026/06/10.md#ts_9',
      );

      expect(result, 'Card not found.');
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
  final imagePath = '${assetsDir.path}/photo.jpg';
  await File(imagePath).writeAsBytes([0, 1, 2, 3]);
  await File('$imagePath.analysis.txt').writeAsString('A test image.');
}

Future<void> _writeCard({
  required String userId,
  required String cardId,
}) async {
  await FileSystemService.instance.safeWriteCardFile(
    userId,
    cardId,
    CardData(
      factId: cardId,
      timestamp: _recordTimestamp,
      status: 'failed',
      tags: ['Visual'],
      title: '测试图片',
      fact: '今天拍了两张图',
      assets: const ['![image](fs://photo.jpg)'],
      address: 'Beijing · Chaoyang Park',
      userFixedTimestamp: _recordTimestamp,
      userFixedAddress: 'Shanghai · Jing’an',
      insight: const CardInsight(summary: 'A useful visual memory.'),
      failureReason: 'LLM timeout',
      comments: [
        CardComment(
          id: 'comment_1',
          content: 'Do not expose this from diagnostics.',
          isAi: false,
          timestamp: _recordTimestamp + 1,
        ),
      ],
      uiConfigs: const [
        UiConfig(
          templateId: 'snapshot',
          data: {'image_url': 'fs://photo.jpg', 'caption': '今天拍了两张图'},
        ),
      ],
    ),
  );
}
