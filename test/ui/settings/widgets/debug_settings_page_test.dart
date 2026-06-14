import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/reprocess_cards_options.dart';
import 'package:memex/ui/settings/widgets/async_task_list_page.dart';
import 'package:memex/ui/settings/widgets/debug_settings_page.dart';
import 'package:memex/ui/settings/widgets/reprocess_cards_dialog.dart';
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

  testWidgets('reprocess cards dialog defaults to card-only mode', (
    tester,
  ) async {
    ReprocessCardsDebugOptions? submitted;

    await _pumpReprocessCardsLauncher(
      tester,
      onSubmitted: (options) {
        submitted = options;
      },
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text(UserStorage.l10n.reprocessCardsCardOnly), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.reprocessCardsRerunDownstream),
      findsOneWidget,
    );

    await tester.tap(find.text(UserStorage.l10n.startProcessing));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.downstreamMode, ReprocessCardsDownstreamMode.cardOnly);
    expect(
      submitted!.toTaskPayload(),
      containsPair(
        ReprocessCardsPayloadKeys.downstreamMode,
        ReprocessCardsDownstreamMode.cardOnly.payloadValue,
      ),
    );
  });

  testWidgets('reprocess cards dialog submits downstream rerun payload', (
    tester,
  ) async {
    ReprocessCardsDebugOptions? submitted;

    await _pumpReprocessCardsLauncher(
      tester,
      onSubmitted: (options) {
        submitted = options;
      },
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('reprocess_cards_limit_field')),
      '3',
    );
    await tester.tap(
      find.byKey(const Key('reprocess_cards_reanalyze_assets_switch')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('reprocess_cards_mode_post_card_router')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(
      find.byKey(const Key('reprocess_cards_mode_post_card_router')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(UserStorage.l10n.startProcessing));
    await tester.pumpAndSettle();

    final payload = submitted!.toTaskPayload();
    expect(
      payload[ReprocessCardsPayloadKeys.downstreamMode],
      ReprocessCardsDownstreamMode.postCardRouter.payloadValue,
    );
    expect(payload['limit'], 3);
    expect(payload['reanalyze_assets'], isTrue);
  });

  testWidgets('task detail shows downstream reprocess result summary', (
    tester,
  ) async {
    final result = jsonEncode({
      'success': 2,
      'failed': 0,
      'total': 2,
      'completed': true,
      'downstream': {
        'mode': ReprocessCardsDownstreamMode.postCardRouter.payloadValue,
        'attempted': 2,
        'succeeded': 2,
        'schedule_aggregation_requested': 1,
        'tasks_enqueued': 2,
        'schedule_item_changes': 'reported_by_schedule_aggregator_task',
        'system_action_changes': 'reported_by_schedule_aggregator_task',
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AsyncTaskDetailDialog(
          task: Task(
            id: 'reprocess_task_1',
            type: 'reprocess_cards_task',
            payload: jsonEncode({
              ReprocessCardsPayloadKeys.downstreamMode:
                  ReprocessCardsDownstreamMode.postCardRouter.payloadValue,
            }),
            status: 'completed',
            priority: 0,
            createdAt: 1770888000,
            scheduledAt: 1770888000,
            completedAt: 1770888060,
            updatedAt: 1770888060,
            retryCount: 0,
            maxRetries: 3,
            result: result,
          ),
        ),
      ),
    );

    expect(find.text('Result:'), findsOneWidget);
    expect(find.textContaining('"success":2'), findsOneWidget);
    expect(find.textContaining('"tasks_enqueued":2'), findsOneWidget);
    expect(
      find.textContaining('"schedule_aggregation_requested":1'),
      findsOneWidget,
    );
    expect(
      find.textContaining('"schedule_item_changes"'),
      findsOneWidget,
    );
    expect(
      find.textContaining('"system_action_changes"'),
      findsOneWidget,
    );
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

Future<void> _pumpReprocessCardsLauncher(
  WidgetTester tester, {
  required void Function(ReprocessCardsDebugOptions options) onSubmitted,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final options = await showReprocessCardsDialog(context);
            if (options != null) onSubmitted(options);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  );
}
