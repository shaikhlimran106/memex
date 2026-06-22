import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/user_storage.dart';

class ModelRoleSelection {
  final String textConfigKey;

  const ModelRoleSelection({
    required this.textConfigKey,
  });
}

class ModelRoleConfigService {
  ModelRoleConfigService._();

  static Future<ModelRoleSelection> loadSelection() async {
    final textKey = await UserStorage.getDefaultLLMConfigKey();

    return ModelRoleSelection(
      textConfigKey: textKey,
    );
  }

  static Future<void> setTextModel(String configKey) async {
    final normalizedKey = _normalizeOptionalKey(configKey);
    if (normalizedKey == null) return;
    await UserStorage.setDefaultLLMConfigKey(normalizedKey);
  }

  static LLMConfig? findConfig(List<LLMConfig> configs, String? configKey) {
    final normalizedKey = _normalizeOptionalKey(configKey);
    if (normalizedKey == null) return null;
    for (final config in configs) {
      if (config.key == normalizedKey) return config;
    }
    return null;
  }

  static String? _normalizeOptionalKey(String? key) {
    final trimmed = key?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}
