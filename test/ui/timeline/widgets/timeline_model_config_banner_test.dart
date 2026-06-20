import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/ui/timeline/widgets/timeline_model_config_banner.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
    EventBusService.instance.clearHandlers();
    await EventBusService.instance.connect();
  });

  tearDown(() async {
    EventBusService.instance.clearHandlers();
    await EventBusService.instance.disconnect();
  });

  testWidgets('banner hides and shows when LLM config events are emitted', (
    tester,
  ) async {
    await _pumpBanner(tester);

    expect(_modelBannerFinder(), findsOneWidget);

    await UserStorage.saveLLMConfigs(const [_validLocalModelConfig]);
    EventBusService.instance.emitEvent(
      LLMConfigChangedMessage(hasValidConfig: true, reason: 'saved'),
    );
    await _pumpAsyncWork(tester);

    expect(_modelBannerFinder(), findsNothing);

    await UserStorage.resetLLMConfigs();
    EventBusService.instance.emitEvent(
      LLMConfigChangedMessage(hasValidConfig: false, reason: 'reset'),
    );
    await _pumpAsyncWork(tester);

    expect(_modelBannerFinder(), findsOneWidget);
  });

  testWidgets('banner rechecks persisted LLM config state on app resume', (
    tester,
  ) async {
    await _pumpBanner(tester);

    expect(_modelBannerFinder(), findsOneWidget);

    await UserStorage.saveLLMConfigs(const [_validLocalModelConfig]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsyncWork(tester);

    expect(_modelBannerFinder(), findsNothing);

    await UserStorage.resetLLMConfigs();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsyncWork(tester);

    expect(_modelBannerFinder(), findsOneWidget);
  });

  testWidgets('banner rechecks after configure flow returns', (tester) async {
    var openedConfig = false;
    await _pumpBanner(
      tester,
      onConfigureTap: () async {
        openedConfig = true;
        await UserStorage.saveLLMConfigs(const [_validLocalModelConfig]);
      },
    );

    expect(_modelBannerFinder(), findsOneWidget);

    await tester.tap(_modelBannerFinder());
    await _pumpAsyncWork(tester);

    expect(openedConfig, isTrue);
    expect(_modelBannerFinder(), findsNothing);
  });
}

Finder _modelBannerFinder() {
  return find.text(UserStorage.l10n.modelNotConfiguredBanner);
}

Future<void> _pumpBanner(
  WidgetTester tester, {
  Future<void> Function()? onConfigureTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TimelineModelConfigBanner(
          onConfigureTap: onConfigureTap ?? () async {},
        ),
      ),
    ),
  );
  await _pumpAsyncWork(tester);
}

Future<void> _pumpAsyncWork(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _validLocalModelConfig = LLMConfig(
  key: 'local-ollama',
  type: LLMConfig.typeOllama,
  modelId: 'llama3',
  apiKey: '',
  baseUrl: 'http://127.0.0.1:11434',
);
