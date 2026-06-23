import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/knowledge_insight/knowledge_insight_skill.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KnowledgeInsightSkill', () {
    late AppDatabase db;
    late Directory tempRoot;
    late String userId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);

      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      userId = 'knowledge_insight_${DateTime.now().microsecondsSinceEpoch}';
      await UserStorage.saveUser(userId);

      tempRoot = await Directory.systemTemp.createTemp('memex_insight_skill_');
      await FileSystemService.init(tempRoot.path);
      EventBusService.instance.clearHandlers();
      await EventBusService.instance.connect();
    });

    tearDown(() async {
      EventBusService.instance.clearHandlers();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
      await db.close();
    });

    test('saving insight cards creates and publishes timeline summary card',
        () async {
      final messages = <EventBusMessage>[];
      EventBusService.instance.addHandler(
        EventBusMessageType.cardAdded,
        messages.add,
      );

      final tool = KnowledgeInsightSkill(forceActivate: true)
          .tools!
          .singleWhere((tool) => tool.name == 'save_knowledge_insight_cards');

      final result = await _runToolCall(
        tool: tool,
        arguments: {
          'cards': [
            {
              'id': 'weekly_focus',
              'template_id': 'summary_card_v1',
              'title': 'Weekly focus',
              'insight': 'The week centered on project work.',
              'type': 'add',
              'data': {'insight_title': 'Weekly focus'},
              'related_facts': ['2026/06/20.md#ts_1'],
              'tags': ['weekly'],
            }
          ],
        },
        metadata: {'userId': userId},
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.isError, isFalse);

      final insight = await FileSystemService.instance
          .readKnowledgeInsightCard(userId, 'weekly_focus');
      expect(insight, isNotNull);
      expect(insight?['title'], 'Weekly focus');

      expect(messages, hasLength(1));
      expect(messages.single, isA<CardAddedMessage>());
      final message = messages.single as CardAddedMessage;
      expect(message.title, UserStorage.l10n.knowledgeNewDiscovery);
      expect(message.tags, ['insight']);
      expect(message.uiConfigs.single.templateId, 'insight_summary');
      expect(
        message.uiConfigs.single.data['added_insight_cards'],
        [
          {'id': 'weekly_focus', 'title': 'Weekly focus'}
        ],
      );

      final summaryCard =
          await FileSystemService.instance.readCardFile(userId, message.id);
      expect(summaryCard, isNotNull);
      expect(summaryCard?.uiConfigs.single.templateId, 'insight_summary');
    });
  });
}

Future<FunctionExecutionResult> _runToolCall({
  required Tool tool,
  required Map<String, dynamic> arguments,
  Map<String, dynamic> metadata = const {},
}) async {
  final client = _SingleToolCallClient(
    toolName: tool.name,
    arguments: arguments,
  );
  final state = AgentState(
    sessionId:
        'knowledge_insight_test_${DateTime.now().microsecondsSinceEpoch}',
    metadata: Map<String, dynamic>.from(metadata),
  );
  final agent = StatefulAgent(
    name: 'knowledge_insight_test_agent',
    client: client,
    modelConfig: ModelConfig(model: 'test-model'),
    state: state,
    tools: [tool],
    withGeneralPrinciples: false,
    maxTurns: 3,
  );

  await agent.run([UserMessage.text('run the tool')], useStream: false);

  final resultMessage =
      state.history.messages.whereType<FunctionExecutionResultMessage>().single;
  return resultMessage.results.single;
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
