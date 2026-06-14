import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/post_card_router_agent/post_card_router_agent.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/data/services/task_handlers/reprocess_cards_handler.dart';
import 'package:memex/domain/models/reprocess_cards_options.dart';

void main() {
  group('handleReprocessCardsWithDependencies', () {
    const userId = 'reprocess_user';
    final factDate = DateTime.parse('2026-05-26T10:00:00');

    test(
      'defaults to card-only mode and does not count downstream work',
      () async {
        final writes = <String, Map<String, dynamic>>{};
        final seenModes = <ReprocessCardsDownstreamMode>[];

        await handleReprocessCardsWithDependencies(
          userId,
          const {},
          TaskContext(
            taskId: 'task_card_only',
            taskType: 'reprocess_cards_task',
          ),
          ReprocessCardsDependencies(
            getTaskResult: (_) async => null,
            updateTaskResult: (taskId, result) async {
              writes[taskId] = jsonDecode(result) as Map<String, dynamic>;
            },
            listAllFacts: (_) async => const ['2026/05/26.md#ts_1'],
            parseFactIdDate: (_) => factDate,
            processOneCard: (
              _,
              __, {
              required reanalyzeAssets,
              required downstreamMode,
              required downstreamRerunFactIds,
            }) async {
              seenModes.add(downstreamMode);
              expect(downstreamRerunFactIds, isEmpty);
              return const ReprocessCardRunResult.success();
            },
          ),
        );

        final result = writes['task_card_only']!;
        expect(result['success'], 1);
        expect(result['failed'], 0);
        expect(seenModes, [ReprocessCardsDownstreamMode.cardOnly]);
        expect(
          result['downstream'],
          containsPair(
            'mode',
            ReprocessCardsDownstreamMode.cardOnly.payloadValue,
          ),
        );
        expect(result['downstream'], containsPair('attempted', 0));
        expect(result['downstream'], containsPair('tasks_enqueued', 0));
      },
    );

    test(
      'rerun mode records router and schedule aggregation summary',
      () async {
        final writes = <String, Map<String, dynamic>>{};

        await handleReprocessCardsWithDependencies(
          userId,
          const {ReprocessCardsPayloadKeys.downstreamMode: 'post_card_router'},
          TaskContext(
            taskId: 'task_downstream',
            taskType: 'reprocess_cards_task',
          ),
          ReprocessCardsDependencies(
            getTaskResult: (_) async => null,
            updateTaskResult: (taskId, result) async {
              writes[taskId] = jsonDecode(result) as Map<String, dynamic>;
            },
            listAllFacts: (_) async => const ['2026/05/26.md#ts_1'],
            parseFactIdDate: (_) => factDate,
            processOneCard: (
              _,
              factId, {
              required reanalyzeAssets,
              required downstreamMode,
              required downstreamRerunFactIds,
            }) async {
              expect(
                downstreamMode,
                ReprocessCardsDownstreamMode.postCardRouter,
              );
              expect(downstreamRerunFactIds.add(factId), isTrue);
              return const ReprocessCardRunResult.success(
                downstream: ReprocessDownstreamResult(
                  status: 'completed',
                  activatedAgents: [
                    PostCardRouterTargets.scheduleAggregator,
                  ],
                  enqueuedTaskIds: ['schedule_task_1'],
                  reason: 'schedule relevant',
                ),
              );
            },
          ),
        );

        final downstream = writes['task_downstream']!['downstream'] as Map;
        expect(downstream['mode'], 'post_card_router');
        expect(downstream['attempted'], 1);
        expect(downstream['succeeded'], 1);
        expect(downstream['schedule_aggregation_requested'], 1);
        expect(downstream['tasks_enqueued'], 1);
        expect(downstream['task_ids'], ['schedule_task_1']);
      },
    );

    test(
      'rerun mode skips duplicate source fact ids within one task',
      () async {
        final writes = <String, Map<String, dynamic>>{};

        await handleReprocessCardsWithDependencies(
          userId,
          const {ReprocessCardsPayloadKeys.downstreamMode: 'post_card_router'},
          TaskContext(
            taskId: 'task_duplicate_fact',
            taskType: 'reprocess_cards_task',
          ),
          ReprocessCardsDependencies(
            getTaskResult: (_) async => null,
            updateTaskResult: (taskId, result) async {
              writes[taskId] = jsonDecode(result) as Map<String, dynamic>;
            },
            listAllFacts: (_) async => const [
              '2026/05/26.md#ts_1',
              '2026/05/26.md#ts_1',
            ],
            parseFactIdDate: (_) => factDate,
            processOneCard: (
              _,
              factId, {
              required reanalyzeAssets,
              required downstreamMode,
              required downstreamRerunFactIds,
            }) async {
              if (!downstreamRerunFactIds.add(factId)) {
                return const ReprocessCardRunResult.success(
                  downstream: ReprocessDownstreamResult.skipped(
                    'downstream_already_rerun_for_fact',
                  ),
                );
              }
              return const ReprocessCardRunResult.success(
                downstream: ReprocessDownstreamResult(
                  status: 'completed',
                  activatedAgents: [
                    PostCardRouterTargets.scheduleAggregator,
                  ],
                  enqueuedTaskIds: ['schedule_task_1'],
                ),
              );
            },
          ),
        );

        final result = writes['task_duplicate_fact']!;
        final downstream = result['downstream'] as Map;
        expect(result['success'], 2);
        expect(downstream['attempted'], 1);
        expect(downstream['skipped'], 1);
        expect(downstream['schedule_aggregation_requested'], 1);
        expect(downstream['tasks_enqueued'], 1);
      },
    );
  });
}
