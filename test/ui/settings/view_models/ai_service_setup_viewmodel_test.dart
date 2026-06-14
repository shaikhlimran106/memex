import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/data/services/model_role_config_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/ui/settings/view_models/ai_service_setup_viewmodel.dart';
import 'package:memex/utils/user_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memex_ai_setup_vm_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    try {
      await tempDir.delete(recursive: true);
    } on PathNotFoundException {
      // Some initialization paths can clean the fake root before tearDown.
    }
  });

  AiServiceSetupViewModel buildViewModel({
    AppConfigFetcher? appConfigFetcher,
  }) {
    final viewModel = AiServiceSetupViewModel(
      router: MemexRouter(),
      appConfigFetcher: appConfigFetcher,
    );
    addTearDown(viewModel.dispose);
    return viewModel;
  }

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

  test('loadModelRoles hydrates role and speech settings', () async {
    await UserStorage.saveLLMConfigs(const [textConfig, visionConfig]);
    await ModelRoleConfigService.setTextModel(textConfig.key);
    await ModelRoleConfigService.setVisionModel(visionConfig.key);
    await UserStorage.setUseLocalSpeechToText(false);

    final viewModel = buildViewModel();
    await viewModel.loadModelRoles();

    expect(viewModel.isRoleLoading, isFalse);
    expect(viewModel.llmConfigs.map((config) => config.key),
        containsAll([textConfig.key, visionConfig.key]));
    expect(viewModel.roleSelection?.textConfigKey, textConfig.key);
    expect(viewModel.roleSelection?.visionConfigKey, visionConfig.key);
    expect(viewModel.useLocalSpeechToText, isFalse);
    expect(viewModel.textConfig?.key, textConfig.key);
    expect(viewModel.effectiveVisionConfig?.key, visionConfig.key);
  });

  test('saveMemexService persists official provider and refreshes roles',
      () async {
    final viewModel = buildViewModel();
    viewModel.setMemexCredentials(
      'https://memex.example/v1',
      'memex-key',
      const ['memex-fast'],
    );

    final saved = await viewModel.saveMemexService();

    final configs = await UserStorage.getLLMConfigs();
    final memexConfig = configs.firstWhere(
      (config) => config.key == LLMConfig.defaultClientKey,
    );

    expect(saved, isTrue);
    expect(memexConfig.type, LLMConfig.typeMemex);
    expect(memexConfig.modelId, 'memex-fast');
    expect(memexConfig.apiKey, 'memex-key');
    expect(memexConfig.baseUrl, 'https://memex.example/v1');
    expect(
        await UserStorage.getDefaultLLMConfigKey(), LLMConfig.defaultClientKey);
    expect(viewModel.isSaving, isFalse);
    expect(viewModel.roleSelection?.textConfigKey, LLMConfig.defaultClientKey);
  });

  test('clearMemexService resets official provider and falls back', () async {
    const memexConfig = LLMConfig(
      key: LLMConfig.defaultClientKey,
      type: LLMConfig.typeMemex,
      modelId: 'memex-fast',
      apiKey: 'memex-key',
      baseUrl: 'https://memex.example/v1',
    );
    await UserStorage.saveLLMConfigs(const [memexConfig, textConfig]);
    await UserStorage.setDefaultLLMConfigKey(LLMConfig.defaultClientKey);

    final viewModel = buildViewModel();
    viewModel.setMemexCredentials(
      memexConfig.baseUrl,
      memexConfig.apiKey,
      [memexConfig.modelId],
    );
    viewModel.setMemexLoginState(true);

    await viewModel.clearMemexService();

    final configs = await UserStorage.getLLMConfigs();
    final defaultConfig = configs.firstWhere(
      (config) => config.key == LLMConfig.defaultClientKey,
    );

    expect(defaultConfig.type, isNot(LLMConfig.typeMemex));
    expect(await UserStorage.getDefaultLLMConfigKey(), textConfig.key);
    expect(viewModel.baseUrl, isEmpty);
    expect(viewModel.apiKey, isEmpty);
    expect(viewModel.models, isEmpty);
    expect(viewModel.isMemexLoggedIn, isFalse);
    expect(viewModel.roleSelection?.textConfigKey, textConfig.key);
  });

  test('showMemexServiceSetup opens setup even when config fetch fails',
      () async {
    String? fetchedLocale;
    final viewModel = buildViewModel(
      appConfigFetcher: ({required String locale}) async {
        fetchedLocale = locale;
        throw Exception('offline');
      },
    );

    await viewModel.showMemexServiceSetup();

    expect(fetchedLocale, 'en');
    expect(viewModel.showMemexSetup, isTrue);
    expect(viewModel.isMemexConfigLoading, isFalse);
  });

  test('model role updates persist and refresh ViewModel state', () async {
    await UserStorage.saveLLMConfigs(const [textConfig, visionConfig]);

    final viewModel = buildViewModel();
    await viewModel.loadModelRoles();

    await viewModel.setTextModel(' ${textConfig.key} ');
    expect(await UserStorage.getDefaultLLMConfigKey(), textConfig.key);
    expect(viewModel.roleSelection?.textConfigKey, textConfig.key);

    await viewModel.setVisionModel(' ${visionConfig.key} ');
    var mediaAgentConfig = await UserStorage.getAgentConfig(
      AgentDefinitions.analyzeAssets,
    );
    expect(mediaAgentConfig.llmConfigKey, visionConfig.key);
    expect(viewModel.roleSelection?.visionConfigKey, visionConfig.key);

    await viewModel.setVisionModel(
      AiServiceSetupViewModel.followTextSelectionValue,
    );
    mediaAgentConfig = await UserStorage.getAgentConfig(
      AgentDefinitions.analyzeAssets,
    );
    expect(mediaAgentConfig.llmConfigKey, isNull);
    expect(viewModel.roleSelection?.visionConfigKey, isNull);
  });
}

class FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String rootPath;

  FakePathProviderPlatform(this.rootPath);

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getExternalStoragePath() async => rootPath;
}
