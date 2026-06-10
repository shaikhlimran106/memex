import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/design_pattern_library.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('DynamicTimelineUiSkill', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.saveUser('test_user');
      tempDir = await Directory.systemTemp.createTemp('memex_dynamic_ui_');
      await FileSystemService.init(tempDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('registers expected tool names', () {
      final skill = DynamicTimelineUiSkill();

      expect(skill.name, 'dynamic_timeline_ui');
      expect(
        skill.tools?.map((tool) => tool.name),
        containsAll([
          'recommend_dynamic_timeline_design_patterns',
          'get_dynamic_timeline_design_pattern',
          'list_dynamic_timeline_design_patterns',
          'create_dynamic_timeline_card',
          'update_dynamic_timeline_card',
        ]),
      );
    });

    test('strips markdown html code fences', () {
      final html = DynamicTimelineUiSkill.sanitizeHtmlForTimeline('''
```html
<section><h1>Focus Review</h1></section>
```
''');

      expect(html, '<section><h1>Focus Review</h1></section>');
    });

    test('rejects executable html', () {
      expect(
        () => DynamicTimelineUiSkill.sanitizeHtmlForTimeline(
          '<section onclick="alert(1)">Tap</section>',
        ),
        throwsArgumentError,
      );
      expect(
        () => DynamicTimelineUiSkill.sanitizeHtmlForTimeline(
          '<script>alert(1)</script>',
        ),
        throwsArgumentError,
      );
    });

    test('normalizes known timeline tags', () {
      expect(
        DynamicTimelineUiSkill.normalizeTimelineTags([
          'visual',
          {'name': 'knowledge'},
          'VISUAL',
          'project',
        ]),
        ['Visual', 'Knowledge', 'Project'],
      );
    });

    test('recommends visual memory pattern for image-heavy intent', () {
      final matches = DynamicTimelineDesignPatternLibrary.recommend(
        intent: 'record two photos from today',
        contentSummary: 'The user sent screenshots and wants a polished memory',
      );

      expect(matches.first.pattern.id, 'visual_memory_editorial');
      expect(matches.first.score, greaterThan(1));
    });

    test('pattern examples are accepted by timeline html sanitizer', () {
      for (final pattern in DynamicTimelineDesignPatternLibrary.patterns) {
        expect(
          DynamicTimelineUiSkill.sanitizeHtmlForTimeline(pattern.htmlExample),
          contains('memex-card'),
        );
      }
    });

    test('rejects unknown timeline tags', () {
      expect(
        () => DynamicTimelineUiSkill.normalizeTimelineTags(['Unknown']),
        throwsArgumentError,
      );
    });

    test('creates fact and legacy html timeline card', () async {
      final card =
          await DynamicTimelineUiSkill.createDynamicTimelineCardForUser(
        userId: 'test_user',
        title: 'Focus dashboard',
        html: '<section><h1>Focus</h1><p>Deep work</p></section>',
        description: 'Created a visual focus dashboard.',
        contentCreationDate: '2026-06-09 20:30:00',
        tags: ['visual'],
        designPatternId: 'visual_memory_editorial',
        designNotes: 'Used the editorial visual-memory layout.',
      );

      expect(card.factId, startsWith('2026/06/09.md#ts_'));
      expect(card.status, 'completed');
      expect(card.tags, ['Visual']);
      expect(card.uiConfigs.single.templateId, 'legacy_html');

      final stored = await FileSystemService.instance.readCardFile(
        'test_user',
        card.factId,
      );
      expect(stored, isNotNull);
      expect(stored!.title, 'Focus dashboard');
      expect(stored.uiConfigs.single.data['html'], contains('Deep work'));
      expect(
        stored.uiConfigs.single.data['design_pattern_id'],
        'visual_memory_editorial',
      );
      expect(
          stored.uiConfigs.single.data['design_notes'], contains('editorial'));

      final factInfo = await FileSystemService.instance
          .extractFactContentFromFile('test_user', card.factId);
      expect(factInfo?.content, contains('visual focus dashboard'));
    });
  });
}
