import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/user_storage.dart';

class ModelRoleSelection {
  final String textConfigKey;
  final String? visionConfigKey;

  const ModelRoleSelection({
    required this.textConfigKey,
    required this.visionConfigKey,
  });

  bool get visionUsesTextModel => visionConfigKey == null;

  String effectiveVisionConfigKey() => visionConfigKey ?? textConfigKey;
}

class ModelRoleConfigService {
  ModelRoleConfigService._();

  static const String visionAgentId = AgentDefinitions.analyzeAssets;

  static Future<ModelRoleSelection> loadSelection() async {
    final textKey = await UserStorage.getDefaultLLMConfigKey();
    final visionConfig = await UserStorage.getAgentConfig(visionAgentId);
    final visionKey = _normalizeOptionalKey(visionConfig.llmConfigKey);

    return ModelRoleSelection(
      textConfigKey: textKey,
      visionConfigKey: visionKey,
    );
  }

  static Future<void> setTextModel(String configKey) {
    return UserStorage.setDefaultLLMConfigKey(configKey);
  }

  static Future<void> setVisionModel(String? configKey) async {
    final normalizedKey = _normalizeOptionalKey(configKey);
    final current = await UserStorage.getAgentConfig(visionAgentId);
    final next = current.copyWith(llmConfigKey: normalizedKey);
    await UserStorage.saveAgentConfig(visionAgentId, next);
  }

  static LLMConfig? findConfig(List<LLMConfig> configs, String? configKey) {
    if (configKey == null || configKey.isEmpty) return null;
    for (final config in configs) {
      if (config.key == configKey) return config;
    }
    return null;
  }

  static String? _normalizeOptionalKey(String? key) {
    final trimmed = key?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}
