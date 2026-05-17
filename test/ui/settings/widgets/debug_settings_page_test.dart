import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/settings/widgets/debug_settings_page.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
  });

  testWidgets('clears failed agent contexts from debugging page', (
    tester,
  ) async {
    var clearCount = 0;

    await _pumpDebugPage(
      tester,
      onClearFailedAgentContexts: () async {
        clearCount += 1;
      },
    );

    final clearButton = find.text(UserStorage.l10n.clearFailedAgentContexts);
    await tester.scrollUntilVisible(
      clearButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(clearButton, findsOneWidget);

    await tester.tap(clearButton);
    await tester.pump();

    expect(clearCount, 1);
  });

  testWidgets('disables clear failed contexts while loading', (tester) async {
    var clearCount = 0;

    await _pumpDebugPage(
      tester,
      isClearingFailedAgentContexts: true,
      onClearFailedAgentContexts: () async {
        clearCount += 1;
      },
    );

    final clearButton = find.text(UserStorage.l10n.clearFailedAgentContexts);
    await tester.scrollUntilVisible(
      clearButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.tap(clearButton);
    await tester.pump();

    expect(clearCount, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

Future<void> _pumpDebugPage(
  WidgetTester tester, {
  Future<void> Function()? onClearFailedAgentContexts,
  bool isClearingFailedAgentContexts = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DebugSettingsPage(
        onClearToken: () async {},
        onClearData: () async {},
        onClearFailedAgentContexts: onClearFailedAgentContexts ?? () async {},
        onReprocessCards: () async {},
        onReprocessComments: () async {},
        onReprocessKnowledgeBase: () async {},
        onRebuildSearchIndex: () async {},
        isClearingData: false,
        isClearingFailedAgentContexts: isClearingFailedAgentContexts,
        isReprocessingCards: false,
        isReprocessingComments: false,
        isReprocessingKnowledgeBase: false,
        isRebuildingSearchIndex: false,
      ),
    ),
  );
}
