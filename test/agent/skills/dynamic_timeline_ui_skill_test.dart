import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/design_pattern_library.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          'preview_dynamic_timeline_card_render',
          'save_timeline_template',
        ]),
      );
      expect(
        skill.tools?.map((tool) => tool.name),
        isNot(contains('create_dynamic_timeline_card')),
      );
      expect(
        skill.tools?.map((tool) => tool.name),
        isNot(contains('update_dynamic_timeline_card')),
      );
      expect(
        skill.tools
            ?.singleWhere(
                (tool) => tool.name == 'preview_dynamic_timeline_card_render')
            .parameterMode,
        ToolParameterMode.object,
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

    test('save_timeline_template requires view.html to exist', () async {
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere((tool) => tool.name == 'save_timeline_template');

      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'template_id': 'missing_template',
          'description': 'Needs existing view.html',
          'use_case': 'Custom rendering for missing template.',
          'fields': [
            {
              'name': 'title',
              'type': 'String',
              'required': true,
              'description': 'Fallback title.',
            },
          ],
        },
        metadata: {'userId': 'test_user'},
      );

      expect(result.isError, isTrue);
      expect(
        _text(result),
        contains('Template HTML is required before saving metadata.'),
      );
    });

    test('preview can target a saved template id', () async {
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere(
              (tool) => tool.name == 'preview_dynamic_timeline_card_render');

      final result = await _runToolCall(
        tool: tool,
        arguments: {'template_id': 'missing_template'},
        metadata: {'userId': 'test_user'},
      );

      expect(result.isError, isTrue);
      expect(_text(result), contains('Template "missing_template"'));
    });

    test('preview can target an existing template id', () async {
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere(
              (tool) => tool.name == 'preview_dynamic_timeline_card_render');

      final result = await _runToolCall(
        tool: tool,
        arguments: {'template_id': 'article'},
        metadata: {'userId': 'test_user'},
      );

      expect(result.isError, isFalse);
      expect(_text(result), contains('current Timeline card style'));
    });

    test('preview fills HTML placeholders with data before rendering',
        () async {
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere(
              (tool) => tool.name == 'preview_dynamic_timeline_card_render');

      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'html': '<section>{{title}}</section>',
          'data': {'title': '<script>alert(1)</script>'},
        },
        metadata: {'userId': 'test_user'},
      );

      expect(result.isError, isTrue);
      expect(_text(result), contains('<script'));
    });

    test('saves timeline template metadata for existing HTML', () async {
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere((tool) => tool.name == 'save_timeline_template');
      await _writeTemplateHtmlFixture(
        userId: 'test_user',
        templateId: 'focus_dashboard',
        htmlContent: '<section><h1>{{title}}</h1><p>{{summary}}</p></section>',
      );
      await FileSystemService.instance.saveTimelineTemplateMeta(
        userId: 'test_user',
        templateId: 'focus_dashboard',
        description: 'A compact dashboard for focus session notes.',
        useCase: 'Focus session notes and compact progress summaries.',
        fields: const [
          TimelineTemplateFieldMeta(
            name: 'title',
            type: 'String',
            required: true,
            description: 'Main focus session title.',
          ),
          TimelineTemplateFieldMeta(
            name: 'summary',
            type: 'String',
            required: true,
            description: 'Short plain-text summary of the session.',
          ),
        ],
      );

      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'template_id': 'focus_dashboard',
          'description': 'A compact dashboard for focus session notes.',
          'use_case': 'Focus session notes and compact progress summaries.',
          'fields': [
            {
              'name': 'title',
              'type': 'String',
              'required': true,
              'description': 'Main focus session title.',
            },
            {
              'name': 'summary',
              'type': 'String',
              'required': true,
              'description': 'Short plain-text summary of the session.',
            },
          ],
        },
        metadata: {'userId': 'test_user'},
      );

      expect(result.isError, isFalse);
      expect(_text(result), contains('Timeline HTML template'));
      final meta = await FileSystemService.instance.readTimelineTemplateMeta(
        'test_user',
        'focus_dashboard',
      );
      expect(meta?.description, contains('focus session'));
      expect(meta?.useCase, contains('Focus session'));
      expect(meta?.fieldNames, ['title', 'summary']);
      expect(meta?.dataStructure, contains('`summary` (String, required)'));
      final html = await FileSystemService.instance.readTemplateHtml(
        'test_user',
        'focus_dashboard',
      );
      expect(html, contains('{{title}}'));
    });

    test('adds current state reminder when overwriting template field schema',
        () async {
      final fileService = FileSystemService.instance;
      await _writeTemplateHtmlFixture(
        userId: 'test_user',
        templateId: 'focus_dashboard',
        htmlContent: '<section>{{title}} {{summary}}</section>',
      );
      await fileService.saveTimelineTemplateMeta(
        userId: 'test_user',
        templateId: 'focus_dashboard',
        description: 'Old template',
        useCase: 'Old focus dashboard.',
        fields: const [
          TimelineTemplateFieldMeta(
            name: 'title',
            type: 'String',
            required: true,
            description: 'Title.',
          ),
          TimelineTemplateFieldMeta(
            name: 'summary',
            type: 'String',
            required: true,
            description: 'Summary.',
          ),
        ],
      );
      const factId = '2026/06/09.md#ts_1';
      await fileService.safeWriteCardFile(
        'test_user',
        factId,
        const CardData(
          factId: factId,
          timestamp: 1781000000,
          status: 'completed',
          tags: ['Project'],
          title: 'Focus',
          uiConfigs: [
            UiConfig(
              templateId: 'focus_dashboard',
              data: {'title': 'Focus', 'summary': 'Deep work'},
            ),
          ],
        ),
      );

      final currentState = AgentState(
        sessionId: 'dynamic_ui_test_current',
        metadata: {'userId': 'test_user'},
      );
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere((tool) => tool.name == 'save_timeline_template');
      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'template_id': 'focus_dashboard',
          'description': 'New template',
          'use_case': 'New focus dashboard.',
          'fields': [
            {
              'name': 'title',
              'type': 'String',
              'required': true,
              'description': 'Title.',
            },
            {
              'name': 'summary',
              'type': 'Number',
              'required': true,
              'description': 'Summary as a numeric score.',
            },
          ],
        },
        state: currentState,
      );

      expect(result.isError, isFalse);
      expect(_text(result), isNot(contains(factId)));
      expect(
        currentState.systemReminders[
            'timeline_template_schema_changed_focus_dashboard'],
        contains(factId),
      );
    });

    test('adds current state reminder when replacing existing template data',
        () async {
      final fileService = FileSystemService.instance;
      const factId = '2026/06/09.md#ts_2';
      await _writeTemplateHtmlFixture(
        userId: 'test_user',
        templateId: 'article',
        htmlContent: '<section>{{summary}}</section>',
      );
      await fileService.saveTimelineTemplateMeta(
        userId: 'test_user',
        templateId: 'article',
        description: 'Custom article replacement.',
        useCase: 'Custom article visual layout.',
        fields: const [
          TimelineTemplateFieldMeta(
            name: 'summary',
            type: 'String',
            required: true,
            description: 'Short article summary.',
          ),
        ],
      );
      await fileService.safeWriteCardFile(
        'test_user',
        factId,
        const CardData(
          factId: factId,
          timestamp: 1781000001,
          status: 'completed',
          tags: ['Knowledge'],
          title: 'Article',
          uiConfigs: [
            UiConfig(
              templateId: 'article',
              data: {'body': 'Existing article body.'},
            ),
          ],
        ),
      );

      final currentState = AgentState(
        sessionId: 'dynamic_ui_test_builtin_override',
        metadata: {'userId': 'test_user'},
      );
      final tool = DynamicTimelineUiSkill(forceActivate: true)
          .tools!
          .singleWhere((tool) => tool.name == 'save_timeline_template');
      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'template_id': 'article',
          'description': 'Custom article replacement.',
          'use_case': 'Custom article visual layout.',
          'fields': [
            {
              'name': 'summary',
              'type': 'Number',
              'required': true,
              'description': 'Summary as a numeric score.',
            },
          ],
        },
        state: currentState,
      );

      expect(result.isError, isFalse);
      expect(_text(result), isNot(contains(factId)));
      final reminder = currentState
          .systemReminders['timeline_template_schema_changed_article'];
      expect(reminder, contains(factId));
      expect(reminder, contains('Existing cards using this template may need'));
    });
  });
}

Future<FunctionExecutionResult> _runToolCall({
  required Tool tool,
  required Map<String, dynamic> arguments,
  Map<String, dynamic> metadata = const {},
  AgentState? state,
}) async {
  final client = _SingleToolCallClient(
    toolName: tool.name,
    arguments: arguments,
  );
  final agentState = state ??
      AgentState(
        sessionId: 'dynamic_ui_test_${DateTime.now().microsecondsSinceEpoch}',
        metadata: Map<String, dynamic>.from(metadata),
      );
  final agent = StatefulAgent(
    name: 'dynamic_ui_test_agent',
    client: client,
    modelConfig: ModelConfig(model: 'test-model'),
    state: agentState,
    tools: [tool],
    withGeneralPrinciples: false,
    maxTurns: 3,
  );

  await agent.run([UserMessage.text('run the tool')], useStream: false);

  final resultMessage = agentState.history.messages
      .whereType<FunctionExecutionResultMessage>()
      .single;
  return resultMessage.results.single;
}

String _text(FunctionExecutionResult result) {
  return result.content
      .whereType<TextPart>()
      .map((part) => part.text)
      .join('\n');
}

Future<void> _writeTemplateHtmlFixture({
  required String userId,
  required String templateId,
  required String htmlContent,
}) async {
  final templatePath =
      FileSystemService.instance.getTemplatePath(userId, templateId);
  await Directory(templatePath).create(recursive: true);
  await File('$templatePath/view.html').writeAsString(htmlContent);
}

class _SingleToolCallClient extends LLMClient {
  _SingleToolCallClient({
    required this.toolName,
    required this.arguments,
  });

  final String toolName;
  final Map<String, dynamic> arguments;
  var _callCount = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    _callCount += 1;
    if (_callCount == 1) {
      return ModelMessage(
        model: modelConfig.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'call_1',
            name: toolName,
            arguments: jsonEncode(arguments),
          ),
        ],
      );
    }
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: 'done',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Streaming is not used by this test client.');
  }
}
