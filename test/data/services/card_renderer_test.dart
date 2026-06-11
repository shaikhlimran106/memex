import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/card_renderer.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/domain/models/card_model.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memex_card_renderer_');
    await FileSystemService.init(tempDir.path);
  });

  tearDown(() async {
    await LocalAssetServer.stopServer();

    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('renderCard replaces fs:// urls inside legacy_html html field', () async {
    const userId = 'legacy_user';
    const sourcePath = 'fs://photo_20260602_ts_1_no_1_800.png';

    final cardData = CardData(
      factId: '2026/06/02.md#ts_1',
      timestamp: 1,
      status: 'completed',
      tags: const [],
      title: 'Legacy HTML',
      uiConfigs: const [
        UiConfig(
          templateId: 'legacy_html',
          data: {
            'html': '<div><img src="$sourcePath" /></div>',
          },
        ),
      ],
    );

    final result = await renderCard(
      userId: userId,
      cardData: cardData,
      factContent: null,
    );

    expect(result.uiConfigs, isNotEmpty);
    final htmlConfig = result.uiConfigs.single;
    final html = htmlConfig.data['html'];

    expect(htmlConfig.templateId, 'legacy_html');
    expect(html, isA<String>());
    expect(
      (html as String),
      allOf(
        contains('http://127.0.0.1:'),
        contains('/assets/$userId/'),
        contains('photo_20260602_ts_1_no_1_800.png'),
        contains('token='),
      ),
    );
  });
}
