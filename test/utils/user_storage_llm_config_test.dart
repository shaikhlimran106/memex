import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/domain/models/agent_config.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/data/services/model_role_config_service.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UserStorage LLM defaults', () {
    test(
      'agents without explicit config use selected global default',
      () async {
        final defaultConfig = LLMConfig.createDefaultClientConfig();
        final customConfig = defaultConfig.copyWith(
          key: 'fast',
          modelId: 'gpt-fast',
        );

        await UserStorage.saveLLMConfigs([defaultConfig, customConfig]);
        expect(
          await UserStorage.getDefaultLLMConfigKey(),
          LLMConfig.defaultClientKey,
        );

        await UserStorage.setDefaultLLMConfigKey(customConfig.key);

        final resolved = await UserStorage.getAgentLLMConfig(
          AgentDefinitions.chatAgent,
          defaultClientKey: LLMConfig.defaultClientKey,
        );

        expect(await UserStorage.getDefaultLLMConfigKey(), customConfig.key);
        expect(resolved.key, customConfig.key);
        expect(resolved.modelId, customConfig.modelId);
      },
    );

    test(
      'removed selected default falls back to legacy default config',
      () async {
        final defaultConfig = LLMConfig.createDefaultClientConfig();
        final customConfig = defaultConfig.copyWith(key: 'custom');

        await UserStorage.saveLLMConfigs([defaultConfig, customConfig]);
        await UserStorage.setDefaultLLMConfigKey(customConfig.key);
        await UserStorage.saveLLMConfigs([defaultConfig]);

        expect(
          await UserStorage.getDefaultLLMConfigKey(),
          LLMConfig.defaultClientKey,
        );
      },
    );

    test('AgentConfig.copyWith can clear explicit model selection', () {
      const config = AgentConfig(llmConfigKey: 'custom');

      expect(config.copyWith(llmConfigKey: null).llmConfigKey, isNull);
    });

    test('DeepSeek builds an OpenAI-compatible chat client', () async {
      const config = LLMConfig(
        key: 'deepseek',
        type: LLMConfig.typeDeepSeek,
        modelId: 'deepseek-v4-flash',
        apiKey: 'sk-test',
        baseUrl: 'https://api.deepseek.com',
      );

      final resources = await UserStorage.buildLLMResources(config);

      expect(resources.client, isA<OpenAIClient>());
      expect(resources.modelConfig.model, 'deepseek-v4-flash');
    });

    test(
      'model role service maps text role to selected global default',
      () async {
        final defaultConfig = LLMConfig.createDefaultClientConfig();
        final textConfig = defaultConfig.copyWith(
          key: 'text-fast',
          modelId: 'text-model',
        );
        await UserStorage.saveLLMConfigs([defaultConfig, textConfig]);

        await ModelRoleConfigService.setTextModel(textConfig.key);

        final selection = await ModelRoleConfigService.loadSelection();
        expect(selection.textConfigKey, textConfig.key);
        expect(selection.visionConfigKey, isNull);
        expect(selection.effectiveVisionConfigKey(), textConfig.key);
        expect(await UserStorage.getDefaultLLMConfigKey(), textConfig.key);
      },
    );

    test(
      'model role service maps vision role to media analysis agent',
      () async {
        final defaultConfig = LLMConfig.createDefaultClientConfig();
        final visionConfig = defaultConfig.copyWith(
          key: 'vision-main',
          modelId: 'gpt-5.4',
        );
        await UserStorage.saveLLMConfigs([defaultConfig, visionConfig]);

        await ModelRoleConfigService.setVisionModel(visionConfig.key);

        final selection = await ModelRoleConfigService.loadSelection();
        final mediaConfig = await UserStorage.getAgentConfig(
          AgentDefinitions.analyzeAssets,
        );
        expect(selection.visionConfigKey, visionConfig.key);
        expect(selection.effectiveVisionConfigKey(), visionConfig.key);
        expect(mediaConfig.llmConfigKey, visionConfig.key);

        await ModelRoleConfigService.setVisionModel(null);
        final resetSelection = await ModelRoleConfigService.loadSelection();
        final resetMediaConfig = await UserStorage.getAgentConfig(
          AgentDefinitions.analyzeAssets,
        );
        expect(resetSelection.visionConfigKey, isNull);
        expect(resetMediaConfig.llmConfigKey, isNull);
      },
    );

    test(
      'model role service normalizes blank vision model keys',
      () async {
        final defaultConfig = LLMConfig.createDefaultClientConfig();
        await UserStorage.saveLLMConfigs([defaultConfig]);
        final prefs = await SharedPreferences.getInstance();
        const agentConfigKey =
            'agent_configs_${AgentDefinitions.analyzeAssets}';

        await prefs.setString(
          agentConfigKey,
          jsonEncode(const AgentConfig(llmConfigKey: '').toJson()),
        );
        final emptySelection = await ModelRoleConfigService.loadSelection();
        expect(emptySelection.visionConfigKey, isNull);
        expect(
          emptySelection.effectiveVisionConfigKey(),
          emptySelection.textConfigKey,
        );

        await prefs.setString(
          agentConfigKey,
          jsonEncode(const AgentConfig(llmConfigKey: '   ').toJson()),
        );
        final whitespaceSelection =
            await ModelRoleConfigService.loadSelection();
        expect(whitespaceSelection.visionConfigKey, isNull);
        expect(
          whitespaceSelection.effectiveVisionConfigKey(),
          whitespaceSelection.textConfigKey,
        );

        await ModelRoleConfigService.setVisionModel('   ');
        final resetMediaConfig = await UserStorage.getAgentConfig(
          AgentDefinitions.analyzeAssets,
        );
        expect(resetMediaConfig.llmConfigKey, isNull);
      },
    );
  });
}
