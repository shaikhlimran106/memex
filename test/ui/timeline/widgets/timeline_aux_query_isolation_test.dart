import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/domain/models/card_detail_model.dart';
import 'package:memex/domain/models/tag_model.dart';
import 'package:memex/domain/models/timeline_card_model.dart';
import 'package:memex/ui/card_attachments/card_attachment_data.dart';
import 'package:memex/ui/core/widgets/agent_logo_loading.dart';
import 'package:memex/ui/timeline/view_models/timeline_viewmodel.dart';
import 'package:memex/ui/timeline/widgets/failed_card_recovery_banner.dart';
import 'package:memex/ui/timeline/widgets/timeline_card_detail_screen.dart';
import 'package:memex/utils/result.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'memex_timeline_aux_query_isolation_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationSupportDirectory':
        case 'getTemporaryDirectory':
          return tempDir.path;
        default:
          return null;
      }
    });
  });

  setUp(() async {
    EventBusService.instance.clearHandlers();
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
  });

  tearDown(() {
    EventBusService.instance.clearHandlers();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets(
    'timeline refresh renders cards and settles while auxiliary queries hang or fail',
    (tester) async {
      final hangingAttachments = Completer<List<CardAttachmentData>>();
      final hangingFailedCount = Completer<int>();
      final vm = _timelineViewModel(
        fetchTimelineCards: ({
          int page = 1,
          int limit = TimelineViewModel.pageLimit,
          List<String>? tags,
          DateTime? dateFrom,
          DateTime? dateTo,
        }) async =>
            Ok([
          _timelineCard('card-hanging-aux', 'Card before hung aux'),
          _timelineCard('card-failing-aux', 'Card before failed aux'),
        ]),
        fetchAttachmentForCard: (factId) {
          if (factId == 'card-hanging-aux') {
            return hangingAttachments.future;
          }
          throw StateError('attachment query failed');
        },
        fetchPendingAttachments: () =>
            Future.error(StateError('pending badge failed')),
        countFailedCardGenerations: () => hangingFailedCount.future,
      );

      await tester.pumpWidget(_TimelineHarness(viewModel: vm));

      final refresh = vm.refresh();
      await tester.pump();

      await expectLater(refresh, completes);
      await tester.pump();

      expect(find.text('Card before hung aux'), findsOneWidget);
      expect(find.text('Card before failed aux'), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline-loading')), findsNothing);
      expect(vm.isLoading, isFalse);
      expect(vm.load.running, isFalse);

      await tester.pump(const Duration(milliseconds: 30));

      expect(vm.pendingAttachmentCount, 0);
      vm.dispose();
    },
  );

  testWidgets(
    'stale refresh return after tab switch does not leave loading on',
    (tester) async {
      final firstRefresh = Completer<Result<List<TimelineCardModel>>>();
      final secondRefresh = Completer<Result<List<TimelineCardModel>>>();
      var calls = 0;
      final vm = _timelineViewModel(
        fetchTimelineCards: ({
          int page = 1,
          int limit = TimelineViewModel.pageLimit,
          List<String>? tags,
          DateTime? dateFrom,
          DateTime? dateTo,
        }) {
          calls += 1;
          return calls == 1 ? firstRefresh.future : secondRefresh.future;
        },
      );

      await tester.pumpWidget(_TimelineHarness(viewModel: vm));

      final staleLoad = vm.loadCards(refresh: true);
      await tester.pump();
      expect(find.byKey(const ValueKey('timeline-loading')), findsOneWidget);

      vm.setActiveFilter('work');
      final currentLoad = vm.loadCards(refresh: true);
      await tester.pump();

      firstRefresh.complete(Ok([_timelineCard('stale-card', 'Stale card')]));
      await tester.pump();
      expect(vm.isLoading, isTrue);
      expect(find.text('Stale card'), findsNothing);

      secondRefresh.complete(Ok([_timelineCard('work-card', 'Work card')]));
      await Future.wait([staleLoad, currentLoad]);
      await tester.pump();

      expect(find.text('Work card'), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline-loading')), findsNothing);
      expect(vm.isLoading, isFalse);

      vm.dispose();
    },
  );

  for (final scenario in [
    _ActiveTaskScenario(
      name: 'hangs',
      fetcher: (_) => Completer<bool>().future,
    ),
    _ActiveTaskScenario(
      name: 'fails',
      fetcher: (_) => Future.error(StateError('task lookup failed')),
    ),
  ]) {
    testWidgets(
      'detail renders main content when hasActiveTaskForCard ${scenario.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: TimelineCardDetailScreen(
              cardId: 'detail-card',
              activeTaskQueryTimeout: const Duration(milliseconds: 10),
              enableRouterSideEffects: false,
              fetchCardDetail: (_) async => _cardDetail(
                title: 'Detail survives ${scenario.name} task lookup',
                content: 'The detail body is visible.',
                status: 'processing',
              ),
              hasActiveTaskForCard: scenario.fetcher,
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(
          find.text('Detail survives ${scenario.name} task lookup'),
          findsOneWidget,
        );
        expect(find.text('The detail body is visible.'), findsOneWidget);
        expect(find.byType(AgentLogoLoading), findsNothing);

        await tester.pump(const Duration(milliseconds: 20));

        expect(find.byType(CardProcessingStatusBanner), findsOneWidget);
        expect(find.text(UserStorage.l10n.cardRegeneratingTitle), findsNothing);
      },
    );
  }
}

TimelineViewModel _timelineViewModel({
  TimelineCardsFetcher? fetchTimelineCards,
  TimelineAttachmentFetcher? fetchAttachmentForCard,
  PendingAttachmentsFetcher? fetchPendingAttachments,
  FailedCardCountFetcher? countFailedCardGenerations,
}) {
  return TimelineViewModel.forTest(
    autoLoad: false,
    auxiliaryQueryTimeout: const Duration(milliseconds: 10),
    fetchTimelineCards: fetchTimelineCards ??
        ({
          int page = 1,
          int limit = TimelineViewModel.pageLimit,
          List<String>? tags,
          DateTime? dateFrom,
          DateTime? dateTo,
        }) async =>
            const Ok([]),
    fetchTags: () async => const Ok(<TagModel>[]),
    fetchScheduleBriefingCard: () async => const Ok(null),
    fetchAttachmentForCard:
        fetchAttachmentForCard ?? (_) async => const <CardAttachmentData>[],
    fetchPendingAttachments:
        fetchPendingAttachments ?? () async => const <CardAttachmentData>[],
    countFailedCardGenerations: countFailedCardGenerations ?? () async => 0,
  );
}

class _TimelineHarness extends StatelessWidget {
  const _TimelineHarness({required this.viewModel});

  final TimelineViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([viewModel, viewModel.load]),
          builder: (context, _) {
            return ListView(
              children: [
                if (viewModel.isLoading || viewModel.load.running)
                  const LinearProgressIndicator(
                    key: ValueKey('timeline-loading'),
                  ),
                for (final card in viewModel.cards)
                  ListTile(title: Text(card.title ?? card.id)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ActiveTaskScenario {
  const _ActiveTaskScenario({required this.name, required this.fetcher});

  final String name;
  final ActiveCardTaskFetcher fetcher;
}

TimelineCardModel _timelineCard(String id, String title) {
  return TimelineCardModel(
    id: id,
    timestamp: DateTime(2026, 6, 16, 9),
    tags: const [],
    status: 'completed',
    title: title,
    uiConfigs: [
      UiConfig(templateId: 'classic_card', data: {'content': title}),
    ],
  );
}

CardDetailModel _cardDetail({
  required String title,
  required String content,
  String status = 'completed',
}) {
  return CardDetailModel(
    id: 'detail-card',
    title: title,
    timestamp: DateTime(2026, 6, 16, 9),
    address: 'Unknown',
    tags: const [],
    rawContent: content,
    insight: InsightData.fromJson(const {}),
    assets: const [],
    uiConfigs: [
      UiConfig(templateId: 'classic_card', data: {'content': content}),
    ],
    status: status,
  );
}
