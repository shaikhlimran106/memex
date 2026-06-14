import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/post_card_router_agent/post_card_router_agent.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PostCardRouterAgent protocol guard', () {
    late Directory tempRoot;
    late String userId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      AgentActivityService.setInstance(LocalAgentActivityService.instance);
      userId = 'router_guard_${DateTime.now().microsecondsSinceEpoch}';
      await UserStorage.saveUser(userId);

      tempRoot = await Directory.systemTemp.createTemp('memex_router_guard_');
      await FileSystemService.init(tempRoot.path);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test(
      'throws retryable protocol error for tool_use without function calls',
      () async {
        await expectLater(
          () => _routeWith(
            userId: userId,
            factId: 'fact_tool_use_without_calls',
            response: ModelMessage(
              model: 'test-model',
              stopReason: 'tool_use',
              textOutput:
                  'select_downstream_agents({"agents":["schedule_aggregator"]})',
            ),
          ),
          throwsA(
            isA<PostCardRouterProtocolException>()
                .having(
                  (e) => e.factId,
                  'factId',
                  'fact_tool_use_without_calls',
                )
                .having((e) => e.stopReason, 'stopReason', 'tool_use'),
          ),
        );
      },
    );

    test('executes structured schedule aggregator tool call', () async {
      final result = await _routeWith(
        userId: userId,
        factId: 'fact_structured_schedule',
        response: _toolCallResponse({
          'agents': [PostCardRouterTargets.scheduleAggregator],
          'reason': 'The input describes a dated schedule item.',
          'confidence': 0.91,
        }),
      );

      expect(result.activatedAgents, [
        PostCardRouterTargets.scheduleAggregator,
      ]);
      expect(result.reason, 'The input describes a dated schedule item.');
      expect(result.confidence, 0.91);
    });

    test('allows structured empty-agent no-op decision', () async {
      final result = await _routeWith(
        userId: userId,
        factId: 'fact_structured_noop',
        response: _toolCallResponse({
          'agents': <String>[],
          'reason': 'No downstream processing is needed.',
        }),
      );

      expect(result.activatedAgents, isEmpty);
      expect(result.reason, 'No downstream processing is needed.');
    });

    test(
      'does not parse tool-shaped text when stop reason is not tool use',
      () async {
        final result = await _routeWith(
          userId: userId,
          factId: 'fact_text_only_no_decision',
          response: ModelMessage(
            model: 'test-model',
            stopReason: 'stop',
            textOutput:
                'select_downstream_agents({"agents":["schedule_aggregator"]})',
          ),
        );

        expect(result.activatedAgents, isEmpty);
        expect(result.reason, 'router_no_decision');
      },
    );
  });
}

Future<PostCardRouteResult> _routeWith({
  required String userId,
  required String factId,
  required ModelMessage response,
}) {
  return PostCardRouterAgent.route(
    client: _SingleResponseClient(response),
    modelConfig: ModelConfig(model: 'test-model'),
    userId: userId,
    factId: factId,
    combinedText: 'Meet Alex tomorrow at 10am.',
    inputMarkdown: '- Raw Input ID (fact_id): $factId\n\n'
        '### Raw Input Content\n'
        'Meet Alex tomorrow at 10am.',
    scheduleStateContext: const {'pending': <Map<String, dynamic>>[]},
  );
}

ModelMessage _toolCallResponse(Map<String, dynamic> arguments) {
  return ModelMessage(
    model: 'test-model',
    stopReason: 'tool_calls',
    functionCalls: [
      FunctionCall(
        id: 'call_1',
        name: 'select_downstream_agents',
        arguments: jsonEncode(arguments),
      ),
    ],
  );
}

class _SingleResponseClient extends LLMClient {
  _SingleResponseClient(this.response);

  final ModelMessage response;
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
    if (_callCount == 1) return response;
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
