import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/config/app_flavor.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/domain/models/llm_config.dart';
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
    AppFlavor.init('global');
    tempDir = await Directory.systemTemp.createTemp('memex_router_llm_event_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
    EventBusService.instance.clearHandlers();
    await EventBusService.instance.connect();
  });

  tearDown(() async {
    EventBusService.instance.clearHandlers();
    await EventBusService.instance.disconnect();
    await LocalAssetServer.stopServer();
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saveLLMConfigs emits typed config change event', () async {
    final messages = <LLMConfigChangedMessage>[];
    EventBusService.instance.addHandler(EventBusMessageType.llmConfigChanged, (
      message,
    ) {
      if (message is LLMConfigChangedMessage) {
        messages.add(message);
      }
    });

    await MemexRouter().saveLLMConfigs(const [_validLocalModelConfig]);
    await Future<void>.delayed(Duration.zero);

    expect(messages, hasLength(1));
    expect(messages.single.hasValidConfig, isTrue);
    expect(messages.single.reason, 'saved');
  });

  test('resetLLMConfigs emits invalid config change event', () async {
    final messages = <LLMConfigChangedMessage>[];
    await UserStorage.saveLLMConfigs(const [_validLocalModelConfig]);
    EventBusService.instance.addHandler(EventBusMessageType.llmConfigChanged, (
      message,
    ) {
      if (message is LLMConfigChangedMessage) {
        messages.add(message);
      }
    });

    await MemexRouter().resetLLMConfigs();
    await Future<void>.delayed(Duration.zero);

    expect(messages, hasLength(1));
    expect(messages.single.hasValidConfig, isFalse);
    expect(messages.single.reason, 'reset');
  });
}

const _validLocalModelConfig = LLMConfig(
  key: 'local-ollama',
  type: LLMConfig.typeOllama,
  modelId: 'llama3',
  apiKey: '',
  baseUrl: 'http://127.0.0.1:11434',
);

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
