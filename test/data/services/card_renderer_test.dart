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

  test('renderCard replaces fs:// urls inside legacy_html html field',
      () async {
    const userId = 'legacy_user';
    const sourcePath = 'fs://photo_20260602_ts_1_no_1_800.png';

    const cardData = CardData(
      factId: '2026/06/02.md#ts_1',
      timestamp: 1,
      status: 'completed',
      tags: [],
      title: 'Legacy HTML',
      uiConfigs: [
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

  test('renderCard prefers saved HTML template over built-in template id',
      () async {
    const userId = 'override_user';
    await FileSystemService.instance.writeTemplateHtml(
      userId: userId,
      templateId: 'article',
      htmlContent: '<section class="custom-article">{{body}}</section>',
    );
    await FileSystemService.instance.saveTimelineTemplateMeta(
      userId: userId,
      templateId: 'article',
      description: 'Custom article layout.',
      useCase: 'Article notes with custom visual style.',
      fields: const [
        TimelineTemplateFieldMeta(
          name: 'body',
          type: 'String',
          required: true,
          description: 'Article body.',
        ),
      ],
    );

    const cardData = CardData(
      factId: '2026/06/02.md#ts_2',
      timestamp: 1,
      status: 'completed',
      tags: [],
      title: 'Custom Article',
      uiConfigs: [
        UiConfig(
          templateId: 'article',
          data: {'body': 'Rendered by the user HTML template.'},
        ),
      ],
    );

    final result = await renderCard(
      userId: userId,
      cardData: cardData,
      factContent: null,
    );

    expect(result.uiConfigs, hasLength(1));
    final config = result.uiConfigs.single;
    expect(config.templateId, 'legacy_html');
    expect(config.data['html'], contains('custom-article'));
    expect(
        config.data['html'], contains('Rendered by the user HTML template.'));
  });
}
