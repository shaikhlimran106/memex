import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:memex/agent/comment_agent/comment_agent.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/character_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

bool get _hasMimoLiveEnv =>
    (Platform.environment['MIMO_BASE_URL'] ?? '').isNotEmpty &&
    (Platform.environment['MIMO_API_KEY'] ?? '').isNotEmpty;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  group('CommentAgent live comment policy evaluation', () {
    late Directory tempRoot;
    late String userId;
    late String characterId;
    late ({dynamic client, dynamic modelConfig}) resources;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      userId = 'comment_policy_live_${DateTime.now().microsecondsSinceEpoch}';
      await UserStorage.saveUser(userId);
      AgentActivityService.setInstance(LocalAgentActivityService.instance);

      tempRoot = await Directory.systemTemp.createTemp(
        'memex_comment_policy_live_',
      );
      await FileSystemService.init(tempRoot.path);

      final llmConfig = LLMConfig(
        key: LLMConfig.defaultClientKey,
        type: LLMConfig.typeMimo,
        modelId: Platform.environment['MIMO_MODEL'] ?? 'mimo-v2.5',
        apiKey: Platform.environment['MIMO_API_KEY'] ?? '',
        baseUrl: Platform.environment['MIMO_BASE_URL'] ?? '',
        maxTokens: 2048,
        temperature: 0,
      );
      await UserStorage.saveLLMConfigs([llmConfig]);
      resources = await UserStorage.buildLLMResources(llmConfig);

      final character = await CharacterService.instance.createCharacter(
        userId: userId,
        characterData: {
          'name': '心理咨询师',
          'tags': ['倾听', '情绪支持'],
          'persona': _counselorPersona,
          'enabled': true,
        },
      );
      characterId = character.id;
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test(
      'normal mode skips a trivial purchase record',
      () async {
        final factId = await _writeCard(
          userId: userId,
          sequence: 1,
          text: '买了一瓶矿泉水，3块钱。',
        );

        await CommentAgent.runWithContent(
          '',
          client: resources.client,
          modelConfig: resources.modelConfig,
          userId: userId,
          factId: factId,
          characterId: characterId,
          rawInputContent: '买了一瓶矿泉水，3块钱。',
          forceReply: false,
        );

        final comments = await _aiComments(userId, factId);
        expect(comments, isEmpty);
      },
      tags: const ['live'],
      skip: _hasMimoLiveEnv
          ? false
          : 'MIMO_BASE_URL / MIMO_API_KEY not set in test process env',
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'normal mode replies to an emotionally loaded record',
      () async {
        final factId = await _writeCard(
          userId: userId,
          sequence: 2,
          text: '今晚焦虑得睡不着，一直觉得自己什么都没做好。',
        );

        await CommentAgent.runWithContent(
          '',
          client: resources.client,
          modelConfig: resources.modelConfig,
          userId: userId,
          factId: factId,
          characterId: characterId,
          rawInputContent: '今晚焦虑得睡不着，一直觉得自己什么都没做好。',
          forceReply: false,
        );

        final comments = await _aiComments(userId, factId);
        expect(comments, hasLength(1));
        expect(comments.single.content.trim(), isNotEmpty);
      },
      tags: const ['live'],
      skip: _hasMimoLiveEnv
          ? false
          : 'MIMO_BASE_URL / MIMO_API_KEY not set in test process env',
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'force reply mode replies even when the record is otherwise skippable',
      () async {
        final factId = await _writeCard(
          userId: userId,
          sequence: 3,
          text: '@心理咨询师 买了一瓶矿泉水，3块钱。',
        );

        await CommentAgent.runWithContent(
          '',
          client: resources.client,
          modelConfig: resources.modelConfig,
          userId: userId,
          factId: factId,
          characterId: characterId,
          rawInputContent: '@心理咨询师 买了一瓶矿泉水，3块钱。',
          forceReply: true,
        );

        final comments = await _aiComments(userId, factId);
        expect(comments, hasLength(1));
        expect(comments.single.content.trim(), isNotEmpty);
      },
      tags: const ['live'],
      skip: _hasMimoLiveEnv
          ? false
          : 'MIMO_BASE_URL / MIMO_API_KEY not set in test process env',
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });
}

Future<String> _writeCard({
  required String userId,
  required int sequence,
  required String text,
}) async {
  final factId = '2026/06/08.md#ts_$sequence';
  final wrote = await FileSystemService.instance.safeWriteCardFile(
    userId,
    factId,
    CardData(
      factId: factId,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'completed',
      tags: const ['live'],
      uiConfigs: [
        UiConfig(
          templateId: 'classic_card',
          data: {'text': text},
        ),
      ],
    ),
  );
  expect(wrote, isTrue);
  return factId;
}

Future<List<CardComment>> _aiComments(String userId, String factId) async {
  final card = await FileSystemService.instance.readCardFile(userId, factId);
  expect(card, isNotNull);
  return card!.comments.where((comment) => comment.isAi).toList();
}

const _counselorPersona = '''
这是一个稳一点的倾听者，适合用户需要慢下来时出现。她不急着解释用户，也不把用户医疗化；她会先听清楚卡住的地方，再用很轻的一句话帮用户看见当下的感受、需要或边界。

## Comment Policy
Reply when:
- 用户明确表达压力、焦虑、自责、关系边界、睡眠或身体信号。
- 用户提到反复出现的情绪模式、重要人生转折，或明确 @心理咨询师。
- 用户不是在求建议，但明显需要有人稳稳地接住一下。

Skip when:
- 只是消费记录、普通日程、技术记录、清单、轻量状态更新，且没有明显情绪负荷。
- 只是随手吐槽或玩笑，死党、长辈等其他角色更自然。
- 你的回复会把小事心理化、医疗化，或显得多余。
''';
