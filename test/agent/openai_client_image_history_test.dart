import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const imageBase64 = 'QUJD';

  test('StatefulAgent keeps previous-turn ImagePart in the second request',
      () async {
    final client = _CapturingClient();
    final agent = StatefulAgent(
      name: 'image_history_test',
      client: client,
      modelConfig: ModelConfig(model: 'test-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
    );

    await agent.run(
      [
        UserMessage([
          TextPart('first turn'),
          ImagePart(imageBase64, 'image/png'),
        ]),
      ],
      useStream: false,
    );
    await agent.run(
      [
        UserMessage([TextPart('second turn')])
      ],
      useStream: false,
    );

    expect(client.calls, hasLength(2));
    final secondCall = client.calls[1];
    final previousUser = secondCall.whereType<UserMessage>().first;
    expect(previousUser.contents.whereType<ImagePart>(), hasLength(1));
    expect(previousUser.contents.whereType<ImagePart>().single.base64Data,
        imageBase64);
  });

  test('OpenAIClient sends historical ImagePart as image_url', () async {
    final bodies = <Map<String, dynamic>>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            bodies.add(Map<String, dynamic>.from(options.data as Map));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                statusMessage: 'OK',
                data: {
                  'id': 'chatcmpl_test',
                  'object': 'chat.completion',
                  'created': 0,
                  'model': 'test-model',
                  'choices': [
                    {
                      'index': 0,
                      'message': {
                        'role': 'assistant',
                        'content': 'ok',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                  'usage': {
                    'prompt_tokens': 1,
                    'completion_tokens': 1,
                    'total_tokens': 2,
                  },
                },
              ),
            );
          },
        ),
      );
    final client = OpenAIClient(
      apiKey: 'test-key',
      baseUrl: 'https://example.invalid/v1',
      client: dio,
      maxRetries: 0,
    );

    await client.generate(
      [
        UserMessage([
          TextPart('first turn'),
          ImagePart(imageBase64, 'image/png'),
        ]),
        ModelMessage(textOutput: 'ok', model: 'test-model'),
        UserMessage([TextPart('second turn')]),
      ],
      modelConfig: ModelConfig(model: 'test-model'),
    );

    expect(bodies, hasLength(1));
    final messages = bodies.single['messages'] as List;
    final firstUser = messages.whereType<Map>().firstWhere(
          (message) => message['role'] == 'user',
        );
    final content = firstUser['content'] as List;
    expect(
      content,
      contains(
        predicate<Map>(
          (part) {
            final imageUrl = part['image_url'];
            return part['type'] == 'image_url' &&
                imageUrl is Map &&
                imageUrl['url'] == 'data:image/png;base64,$imageBase64';
          },
        ),
      ),
    );
  });
}

class _CapturingClient extends LLMClient {
  final calls = <List<LLMMessage>>[];

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    calls.add(List<LLMMessage>.from(messages));
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: 'ok ${calls.length}',
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
  }) {
    throw UnsupportedError('stream is not used by this test');
  }
}
