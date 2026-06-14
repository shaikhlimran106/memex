import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/model_role_config_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ModelRoleConfigService', () {
    const textConfig = LLMConfig(
      key: 'text-main',
      type: LLMConfig.typeChatCompletion,
      modelId: 'gpt-5.4-mini',
      apiKey: 'sk-test',
      baseUrl: 'https://api.openai.com/v1',
    );

    const visionConfig = LLMConfig(
      key: 'vision-main',
      type: LLMConfig.typeChatCompletion,
      modelId: 'gpt-5.4',
      apiKey: 'sk-test',
      baseUrl: 'https://api.openai.com/v1',
    );

    test('findConfig handles empty inputs and normalizes keys', () {
      expect(
          ModelRoleConfigService.findConfig(const [], textConfig.key), isNull);
      expect(
        ModelRoleConfigService.findConfig(const [textConfig], null),
        isNull,
      );
      expect(
        ModelRoleConfigService.findConfig(const [textConfig], ''),
        isNull,
      );
      expect(
        ModelRoleConfigService.findConfig(const [textConfig], '   '),
        isNull,
      );
      expect(
        ModelRoleConfigService.findConfig(
          const [textConfig],
          ' ${textConfig.key} ',
        ),
        same(textConfig),
      );
      expect(
        ModelRoleConfigService.findConfig(const [textConfig], 'missing'),
        isNull,
      );
    });

    test('loadSelection and setters normalize blank role keys', () async {
      await UserStorage.saveLLMConfigs(const [textConfig, visionConfig]);
      await ModelRoleConfigService.setTextModel(' ${textConfig.key} ');
      await ModelRoleConfigService.setVisionModel(' ${visionConfig.key} ');

      final selection = await ModelRoleConfigService.loadSelection();
      final mediaAgentConfig = await UserStorage.getAgentConfig(
        AgentDefinitions.analyzeAssets,
      );

      expect(selection.textConfigKey, textConfig.key);
      expect(selection.visionConfigKey, visionConfig.key);
      expect(mediaAgentConfig.llmConfigKey, visionConfig.key);

      await ModelRoleConfigService.setVisionModel('   ');
      final resetSelection = await ModelRoleConfigService.loadSelection();
      final resetMediaAgentConfig = await UserStorage.getAgentConfig(
        AgentDefinitions.analyzeAssets,
      );

      expect(resetSelection.visionConfigKey, isNull);
      expect(resetMediaAgentConfig.llmConfigKey, isNull);
    });
  });
}
