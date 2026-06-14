import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/config/app_flavor.dart';
import 'package:memex/data/services/settings_registry.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/ui/settings/widgets/ai_service_setup_page.dart';
import 'package:memex/ui/settings/widgets/model_config_edit_page.dart';
import 'package:memex/ui/settings/widgets/model_config_list_page.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppFlavor.init('global');
    SharedPreferences.setMockInitialValues({'language': 'zh'});
    await UserStorage.initL10n();
  });

  testWidgets('renders model roles plus Memex and custom setup options', (
    tester,
  ) async {
    await _pumpPage(tester, const AiServiceSetupPage());

    expect(find.text(UserStorage.l10n.aiModelHubTitle), findsWidgets);
    expect(find.text(UserStorage.l10n.aiModelHubSubtitle), findsOneWidget);
    expect(find.text(UserStorage.l10n.modelRolesTitle), findsOneWidget);
    expect(find.text(UserStorage.l10n.textModelRoleTitle), findsOneWidget);
    expect(find.text(UserStorage.l10n.visionModelRoleTitle), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.aiServiceMemexRouteTitle),
      findsOneWidget,
    );
    expect(
      find.text(UserStorage.l10n.aiServiceCustomApiRouteTitle),
      findsOneWidget,
    );
    expect(
      find.text(UserStorage.l10n.aiServiceCustomModelDescription),
      findsOneWidget,
    );
    expect(
      find.text(UserStorage.l10n.aiServiceSettingsDescription),
      findsOneWidget,
    );
    expect(find.text(UserStorage.l10n.enableAiService), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.advancedModelConfiguration),
      findsOneWidget,
    );
    expect(find.text(UserStorage.l10n.aiServiceLongDescription), findsNothing);
    expect(find.text(UserStorage.l10n.memexUsername), findsNothing);
    expect(find.text(UserStorage.l10n.memexPassword), findsNothing);
  });

  testWidgets('settings registry model config entry opens AI model hub', (
    tester,
  ) async {
    final item = SettingsRegistry.allItems.firstWhere(
      (item) => item.id == 'model_config',
    );
    late Widget targetPage;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            targetPage = item.navigationTarget.pageBuilder(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(item.title, UserStorage.l10n.aiModelHubTitle);
    expect(item.description, UserStorage.l10n.aiModelHubSubtitle);
    expect(targetPage, isA<AiServiceSetupPage>());
  });

  testWidgets('model role selectors update default and media agent model', (
    tester,
  ) async {
    const textConfig = LLMConfig(
      key: 'text-fast',
      type: LLMConfig.typeDeepSeek,
      modelId: 'deepseek-v4-flash',
      apiKey: 'sk-text',
      baseUrl: 'https://api.deepseek.com',
    );
    const visionConfig = LLMConfig(
      key: 'vision-main',
      type: LLMConfig.typeChatCompletion,
      modelId: 'gpt-5.4',
      apiKey: 'sk-vision',
      baseUrl: 'https://api.openai.com/v1',
    );
    await UserStorage.saveLLMConfigs([
      LLMConfig.createDefaultClientConfig(),
      textConfig,
      visionConfig,
    ]);

    await _pumpPage(tester, const AiServiceSetupPage());

    final textDropdown = find.byKey(
      const ValueKey('ai-model-text-slot-dropdown'),
    );
    await tester.ensureVisible(textDropdown);
    await tester.tap(textDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(textConfig.key).last);
    await tester.pumpAndSettle();

    expect(await UserStorage.getDefaultLLMConfigKey(), textConfig.key);

    final visionDropdown = find.byKey(
      const ValueKey('ai-model-vision-slot-dropdown'),
    );
    await tester.ensureVisible(visionDropdown);
    await tester.tap(visionDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(visionConfig.key).last);
    await tester.pumpAndSettle();

    final mediaConfig = await UserStorage.getAgentConfig(
      AgentDefinitions.analyzeAssets,
    );
    expect(mediaConfig.llmConfigKey, visionConfig.key);

    await tester.ensureVisible(visionDropdown);
    await tester.tap(visionDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(UserStorage.l10n.followTextModel).last);
    await tester.pumpAndSettle();

    final resetMediaConfig = await UserStorage.getAgentConfig(
      AgentDefinitions.analyzeAssets,
    );
    expect(resetMediaConfig.llmConfigKey, isNull);
  });

  testWidgets('vision selector warns when selected model is not multimodal', (
    tester,
  ) async {
    const multimodalConfig = LLMConfig(
      key: 'vision-ready',
      type: LLMConfig.typeChatCompletion,
      modelId: 'gpt-4o',
      apiKey: 'sk-vision',
      baseUrl: 'https://api.openai.com/v1',
    );
    const textOnlyConfig = LLMConfig(
      key: 'text-only',
      type: LLMConfig.typeDeepSeek,
      modelId: 'deepseek-v4-flash',
      apiKey: 'sk-text',
      baseUrl: 'https://api.deepseek.com',
    );
    await UserStorage.saveLLMConfigs([
      LLMConfig.createDefaultClientConfig(),
      multimodalConfig,
      textOnlyConfig,
    ]);
    await UserStorage.setDefaultLLMConfigKey(multimodalConfig.key);

    await _pumpPage(tester, const AiServiceSetupPage());

    expect(
      find.text(UserStorage.l10n.visionModelNonMultimodalWarning),
      findsNothing,
    );

    final visionDropdown = find.byKey(
      const ValueKey('ai-model-vision-slot-dropdown'),
    );
    await tester.ensureVisible(visionDropdown);
    await tester.tap(visionDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(textOnlyConfig.key).last);
    await tester.pumpAndSettle();

    expect(
      find.text(UserStorage.l10n.visionModelNonMultimodalWarning),
      findsOneWidget,
    );
  });

  testWidgets('speech transcription switch persists the local setting', (
    tester,
  ) async {
    await UserStorage.setUseLocalSpeechToText(true);
    await _pumpPage(tester, const AiServiceSetupPage());

    final speechSwitch = find.byKey(
      const ValueKey('ai-service-speech-local-switch'),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(speechSwitch, findsOneWidget);
    await tester.tap(speechSwitch);
    await tester.pumpAndSettle();

    expect(await UserStorage.getUseLocalSpeechToText(), isFalse);
  });

  testWidgets('Memex service action expands auth form', (tester) async {
    await _pumpPage(tester, const AiServiceSetupPage());

    await tester.tap(find.text(UserStorage.l10n.enableAiService));
    await tester.pumpAndSettle();

    expect(find.text(UserStorage.l10n.memexUsername), findsOneWidget);
    expect(find.text(UserStorage.l10n.memexPassword), findsOneWidget);
  });

  testWidgets('custom model action opens model configuration', (tester) async {
    await _pumpPage(tester, const AiServiceSetupPage());

    final customModelAction = find.byKey(
      const ValueKey('ai-model-custom-config-button'),
    );
    await _centerFinder(tester, customModelAction);
    await tester.tap(customModelAction);
    await tester.pumpAndSettle();

    expect(find.byType(ModelConfigEditPage), findsOneWidget);
    expect(find.byType(ModelConfigListPage), findsNothing);
    expect(find.text(UserStorage.l10n.keyIdLabel), findsNothing);
  });

  testWidgets('onboarding skip completes without saving credentials', (
    tester,
  ) async {
    var completed = false;

    await _pumpPage(
      tester,
      AiServiceSetupPage(
        onboardingMode: true,
        onComplete: () => completed = true,
      ),
    );

    await tester.tap(find.text(UserStorage.l10n.skipForNow));
    await tester.pump();

    expect(completed, isTrue);
  });

  testWidgets('onboarding custom model save completes setup flow', (
    tester,
  ) async {
    var completed = false;
    const customConfig = LLMConfig(
      key: 'custom-openai',
      type: LLMConfig.typeChatCompletion,
      modelId: 'gpt-4o',
      apiKey: 'sk-test',
      baseUrl: 'https://api.openai.com/v1',
    );
    await UserStorage.saveLLMConfigs([
      LLMConfig.createDefaultClientConfig(),
      customConfig,
    ]);
    await UserStorage.saveLLMConsent(
      true,
      providerType: LLMConfig.typeChatCompletion,
    );

    await _pumpPage(
      tester,
      AiServiceSetupPage(
        onboardingMode: true,
        onComplete: () => completed = true,
      ),
    );

    final customModelAction = find.byKey(
      const ValueKey('ai-model-custom-config-button'),
    );
    await _centerFinder(tester, customModelAction);
    await tester.tap(customModelAction);
    await tester.pumpAndSettle();

    await tester.tap(find.text(customConfig.key));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(find.byType(ModelConfigListPage), findsNothing);
  });
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(430, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}

Future<void> _centerFinder(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(
    tester.element(finder),
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
}
