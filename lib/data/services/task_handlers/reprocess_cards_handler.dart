import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:memex/agent/post_card_router_agent/post_card_router_agent.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/data/services/task_handlers/analyze_assets_handler.dart';
import 'package:memex/data/services/task_handlers/card_agent_handler.dart';
import 'package:memex/data/services/task_handlers/llm_error_utils.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/domain/models/reprocess_cards_options.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

final Logger _logger = getLogger('ReprocessCardsHandler');

/// Number of cards to process per batch (concurrently).
const int _batchSize = 10;

/// Task Handler implementation for `reprocess_cards_task`.
///
/// Supports resuming from where the previous run left off.
Future<void> handleReprocessCardsImpl(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
) async {
  await handleReprocessCardsWithDependencies(
    userId,
    payload,
    context,
    const ReprocessCardsDependencies(),
  );
}

typedef ReprocessOneCard = Future<ReprocessCardRunResult> Function(
  String userId,
  String factId, {
  required bool reanalyzeAssets,
  required ReprocessCardsDownstreamMode downstreamMode,
  required Set<String> downstreamRerunFactIds,
});

typedef ReprocessTaskResultReader = Future<Map<String, dynamic>?> Function(
    String taskId);

typedef ReprocessTaskResultWriter = Future<void> Function(
    String taskId, String result);

@visibleForTesting
class ReprocessCardsDependencies {
  const ReprocessCardsDependencies({
    this.listAllFacts,
    this.parseFactIdDate,
    this.processOneCard,
    this.getTaskResult,
    this.updateTaskResult,
  });

  final Future<List<String>> Function(String userId)? listAllFacts;
  final DateTime Function(String factId)? parseFactIdDate;
  final ReprocessOneCard? processOneCard;
  final ReprocessTaskResultReader? getTaskResult;
  final ReprocessTaskResultWriter? updateTaskResult;
}

@visibleForTesting
class ReprocessCardRunResult {
  const ReprocessCardRunResult({
    required this.success,
    this.downstream = const ReprocessDownstreamResult.cardOnly(),
  });

  const ReprocessCardRunResult.success({
    this.downstream = const ReprocessDownstreamResult.cardOnly(),
  }) : success = true;

  const ReprocessCardRunResult.failure()
      : success = false,
        downstream = const ReprocessDownstreamResult.cardOnly();

  final bool success;
  final ReprocessDownstreamResult downstream;
}

@visibleForTesting
class ReprocessDownstreamResult {
  const ReprocessDownstreamResult({
    required this.status,
    this.activatedAgents = const [],
    this.enqueuedTaskIds = const [],
    this.reason,
    this.error,
  });

  const ReprocessDownstreamResult.cardOnly()
      : status = 'card_only',
        activatedAgents = const [],
        enqueuedTaskIds = const [],
        reason = null,
        error = null;

  const ReprocessDownstreamResult.skipped(String this.reason)
      : status = 'skipped',
        activatedAgents = const [],
        enqueuedTaskIds = const [],
        error = null;

  const ReprocessDownstreamResult.failed(String this.error)
      : status = 'failed',
        activatedAgents = const [],
        enqueuedTaskIds = const [],
        reason = null;

  final String status;
  final List<String> activatedAgents;
  final List<String> enqueuedTaskIds;
  final String? reason;
  final String? error;

  bool get attempted => status == 'completed' || status == 'failed';
  bool get completed => status == 'completed';
  bool get failed => status == 'failed';
  bool get requestedScheduleAggregation =>
      activatedAgents.contains(PostCardRouterTargets.scheduleAggregator);

  Map<String, dynamic> toJson() => {
        'status': status,
        if (activatedAgents.isNotEmpty) 'activated_agents': activatedAgents,
        if (enqueuedTaskIds.isNotEmpty) 'enqueued_task_ids': enqueuedTaskIds,
        if (reason != null) 'reason': reason,
        if (error != null) 'error': error,
      };
}

@visibleForTesting
Future<void> handleReprocessCardsWithDependencies(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
  ReprocessCardsDependencies dependencies,
) async {
  _logger.info('Starting reprocess cards task for user: $userId');

  try {
    final getTaskResult = dependencies.getTaskResult ??
        (taskId) => LocalTaskExecutor.instance.getTaskResult(taskId);
    final updateTaskResult = dependencies.updateTaskResult ??
        (taskId, result) =>
            LocalTaskExecutor.instance.updateTaskResult(taskId, result);
    final processOneCard = dependencies.processOneCard ?? _processOneCard;
    final downstreamMode = ReprocessCardsDownstreamMode.fromPayload(
      payload[ReprocessCardsPayloadKeys.downstreamMode],
    );

    // 1. Get or restore progress.
    Map<String, dynamic>? progress;
    try {
      final existingResult = await getTaskResult(context.taskId);
      if (existingResult != null && existingResult.containsKey('progress')) {
        progress = existingResult['progress'] as Map<String, dynamic>;
        _logger.info(
          'Resuming from progress: ${progress['currentIndex']}/${progress['total']}',
        );
      }
    } catch (e) {
      _logger.warning('Failed to retrieve progress: $e');
    }

    // 2. Get the fact list to process.
    List<String> factIds;
    int currentIndex;
    int successCount;
    int failCount;
    var downstreamAttemptedCount = 0;
    var downstreamSuccessCount = 0;
    var downstreamFailCount = 0;
    var downstreamSkippedCount = 0;
    var scheduleAggregationRequestedCount = 0;
    var downstreamTasksEnqueuedCount = 0;
    final downstreamTaskIds = <String>[];
    final downstreamRerunFactIds = <String>{};

    if (progress != null) {
      // Restore from saved progress; safely perform type conversion.
      final rawFactIds = progress['factIds'] as List;
      factIds = rawFactIds.map((e) => e.toString()).toList();
      currentIndex = progress['currentIndex'] as int;
      successCount = progress['successCount'] as int? ?? 0;
      failCount = progress['failCount'] as int? ?? 0;
      downstreamAttemptedCount =
          progress['downstreamAttemptedCount'] as int? ?? 0;
      downstreamSuccessCount = progress['downstreamSuccessCount'] as int? ?? 0;
      downstreamFailCount = progress['downstreamFailCount'] as int? ?? 0;
      downstreamSkippedCount = progress['downstreamSkippedCount'] as int? ?? 0;
      scheduleAggregationRequestedCount =
          progress['scheduleAggregationRequestedCount'] as int? ?? 0;
      downstreamTasksEnqueuedCount =
          progress['downstreamTasksEnqueuedCount'] as int? ?? 0;
      final rawDownstreamTaskIds =
          progress['downstreamTaskIds'] as List<dynamic>? ?? const [];
      downstreamTaskIds.addAll(rawDownstreamTaskIds.map((e) => e.toString()));
      final rawRerunFactIds =
          progress['downstreamRerunFactIds'] as List<dynamic>? ?? const [];
      downstreamRerunFactIds.addAll(rawRerunFactIds.map((e) => e.toString()));
      _logger.info('Resuming from index $currentIndex');
    } else {
      // Get filter conditions from payload.
      final dateFromStr = payload['date_from'] as String?;
      final dateToStr = payload['date_to'] as String?;
      final limit = payload['limit'] as int?;

      DateTime? dateFrom;
      DateTime? dateTo;

      if (dateFromStr != null) {
        try {
          dateFrom = DateTime.parse(dateFromStr);
        } catch (e) {
          _logger.warning('Invalid date_from format: $dateFromStr');
        }
      }

      if (dateToStr != null) {
        try {
          dateTo = DateTime.parse(dateToStr);
          dateTo = DateTime(dateTo.year, dateTo.month, dateTo.day, 23, 59, 59);
        } catch (e) {
          _logger.warning('Invalid date_to format: $dateToStr');
        }
      }

      // List all facts.
      _logger.info('Listing all facts...');
      final listAllFacts =
          dependencies.listAllFacts ?? FileSystemService.instance.listAllFacts;
      final parseFactIdDate = dependencies.parseFactIdDate ??
          FileSystemService.instance.parseFactIdDate;
      final allFactIds = await listAllFacts(userId);
      _logger.info('Found ${allFactIds.length} facts');

      // filter facts
      factIds = <String>[];
      for (final factId in allFactIds) {
        try {
          final factDate = parseFactIdDate(factId);
          final cardDate = DateTime(
            factDate.year,
            factDate.month,
            factDate.day,
          );

          if (dateFrom != null && cardDate.isBefore(dateFrom)) {
            continue;
          }
          if (dateTo != null && cardDate.isAfter(dateTo)) {
            continue;
          }

          factIds.add(factId);
        } catch (e) {
          _logger.warning('Failed to parse fact date for $factId: $e');
          continue;
        }
      }

      // Apply limit.
      if (limit != null && limit > 0 && factIds.length > limit) {
        factIds = factIds.take(limit).toList();
      }

      currentIndex = 0;
      successCount = 0;
      failCount = 0;

      // Save initial progress.
      await _saveProgress(
        context.taskId,
        factIds,
        currentIndex,
        successCount,
        failCount,
        downstreamMode: downstreamMode,
        downstreamAttemptedCount: downstreamAttemptedCount,
        downstreamSuccessCount: downstreamSuccessCount,
        downstreamFailCount: downstreamFailCount,
        downstreamSkippedCount: downstreamSkippedCount,
        scheduleAggregationRequestedCount: scheduleAggregationRequestedCount,
        downstreamTasksEnqueuedCount: downstreamTasksEnqueuedCount,
        downstreamTaskIds: downstreamTaskIds,
        downstreamRerunFactIds: downstreamRerunFactIds,
        updateTaskResult: updateTaskResult,
      );
    }

    final total = factIds.length;
    _logger.info(
      'Processing ${total - currentIndex} cards (starting from index $currentIndex), batch size: $_batchSize',
    );

    final reanalyzeAssets = payload['reanalyze_assets'] as bool? ?? false;

    // 3. Process in batches: up to [_batchSize] cards per batch concurrently; run next batch after current batch completes.
    while (currentIndex < factIds.length) {
      final endIndex = (currentIndex + _batchSize).clamp(0, total);
      final batch = factIds.sublist(currentIndex, endIndex);
      final batchNumber = currentIndex ~/ _batchSize + 1;
      final totalBatches = (total + _batchSize - 1) ~/ _batchSize;

      _logger.info(
        'Processing batch $batchNumber/$totalBatches: cards ${currentIndex + 1}-$endIndex of $total',
      );

      final results = await Future.wait(
        batch.map(
          (factId) => processOneCard(
            userId,
            factId,
            reanalyzeAssets: reanalyzeAssets,
            downstreamMode: downstreamMode,
            downstreamRerunFactIds: downstreamRerunFactIds,
          ),
        ),
      );

      for (var i = 0; i < results.length; i++) {
        final result = results[i];
        if (result.success) {
          successCount++;
          _logger.info('Successfully processed card: ${batch[i]}');
          final downstream = result.downstream;
          if (downstreamMode.rerunDownstream) {
            if (downstream.attempted) downstreamAttemptedCount++;
            if (downstream.completed) downstreamSuccessCount++;
            if (downstream.failed) downstreamFailCount++;
            if (downstream.status == 'skipped') downstreamSkippedCount++;
            if (downstream.requestedScheduleAggregation) {
              scheduleAggregationRequestedCount++;
            }
            downstreamTasksEnqueuedCount += downstream.enqueuedTaskIds.length;
            downstreamTaskIds.addAll(downstream.enqueuedTaskIds);
          }
        } else {
          failCount++;
        }
      }

      currentIndex = endIndex;

      // Save progress after each batch completes.
      await _saveProgress(
        context.taskId,
        factIds,
        currentIndex,
        successCount,
        failCount,
        downstreamMode: downstreamMode,
        downstreamAttemptedCount: downstreamAttemptedCount,
        downstreamSuccessCount: downstreamSuccessCount,
        downstreamFailCount: downstreamFailCount,
        downstreamSkippedCount: downstreamSkippedCount,
        scheduleAggregationRequestedCount: scheduleAggregationRequestedCount,
        downstreamTasksEnqueuedCount: downstreamTasksEnqueuedCount,
        downstreamTaskIds: downstreamTaskIds,
        downstreamRerunFactIds: downstreamRerunFactIds,
        updateTaskResult: updateTaskResult,
      );
    }

    // 4. Save final result.
    final result = {
      'success': successCount,
      'failed': failCount,
      'total': total,
      'completed': true,
      'downstream': _downstreamSummaryJson(
        downstreamMode: downstreamMode,
        attemptedCount: downstreamAttemptedCount,
        successCount: downstreamSuccessCount,
        failCount: downstreamFailCount,
        skippedCount: downstreamSkippedCount,
        scheduleAggregationRequestedCount: scheduleAggregationRequestedCount,
        tasksEnqueuedCount: downstreamTasksEnqueuedCount,
        taskIds: downstreamTaskIds,
      ),
    };

    await updateTaskResult(context.taskId, jsonEncode(result));

    _logger.info(
      'Reprocess cards task completed. Success: $successCount, Failed: $failCount, Total: $total',
    );
  } catch (e, stack) {
    _logger.severe('Error in reprocess cards task: $e', e, stack);
    rethrowIfNonRetryable(e);
  }
}

/// Processes one card: extract content, optionally refresh media analysis, ensure card exists, call card_agent. Returns whether it succeeded.
Future<ReprocessCardRunResult> _processOneCard(
  String userId,
  String factId, {
  required bool reanalyzeAssets,
  required ReprocessCardsDownstreamMode downstreamMode,
  required Set<String> downstreamRerunFactIds,
}) async {
  FactContentResult? factInfo;
  try {
    final fileSystem = FileSystemService.instance;
    factInfo = await fileSystem.extractFactContentFromFile(userId, factId);

    if (factInfo == null) {
      _logger.warning('Failed to extract fact content for: $factId');
      return const ReprocessCardRunResult.failure();
    }

    await _ensureCardExists(fileSystem, userId, factId, factInfo.datetime);

    var assetAnalyses = factInfo.assetAnalyses;
    if (reanalyzeAssets) {
      final assetPaths = _extractAssetPaths(
        fileSystem,
        userId,
        factInfo.content,
      );
      if (assetPaths.isNotEmpty) {
        _logger.info('Re-analyzing ${assetPaths.length} asset(s) for $factId');
        final refreshedAnalyses = await analyzeAssetsForFact(
          userId: userId,
          factId: factId,
          assetPaths: assetPaths,
        );
        assetAnalyses = refreshedAnalyses.map((e) => e.toJson()).toList();
      }
    }

    await processWithCardAgent(
      userId: userId,
      factId: factId,
      contentText: factInfo.content,
      assetAnalyses: assetAnalyses,
      inputDateTime: factInfo.datetime,
      dryRun: false,
    );

    await renderAndPushCardUpdate(userId, factId, factInfo.content);

    final downstream = await _rerunDownstreamIfRequested(
      userId: userId,
      factId: factId,
      factInfo: factInfo,
      downstreamMode: downstreamMode,
      downstreamRerunFactIds: downstreamRerunFactIds,
    );

    return ReprocessCardRunResult.success(downstream: downstream);
  } catch (e, stack) {
    _logger.severe('Failed to reprocess card $factId: $e', e, stack);
    return const ReprocessCardRunResult.failure();
  } finally {
    factInfo = null;
  }
}

Future<ReprocessDownstreamResult> _rerunDownstreamIfRequested({
  required String userId,
  required String factId,
  required FactContentResult factInfo,
  required ReprocessCardsDownstreamMode downstreamMode,
  required Set<String> downstreamRerunFactIds,
}) async {
  if (!downstreamMode.rerunDownstream) {
    return const ReprocessDownstreamResult.cardOnly();
  }
  if (!downstreamRerunFactIds.add(factId)) {
    return const ReprocessDownstreamResult.skipped(
      'downstream_already_rerun_for_fact',
    );
  }

  try {
    final llmConfig = await UserStorage.getAgentLLMConfig(
      AgentDefinitions.postCardRouterAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );
    if (!llmConfig.isValid) {
      return const ReprocessDownstreamResult.skipped(
        'post_card_router_llm_config_missing',
      );
    }

    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.postCardRouterAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );
    final routeResult = await runPostCardRouter(
      userId: userId,
      factId: factId,
      combinedText: factInfo.content,
      assetAnalyses: factInfo.assetAnalyses,
      inputDateTime: factInfo.datetime,
      client: resources.client,
      modelConfig: resources.modelConfig,
      dedupeScheduleItemsBySourceFactId: true,
    );
    return ReprocessDownstreamResult(
      status: 'completed',
      activatedAgents: routeResult.activatedAgents,
      enqueuedTaskIds: routeResult.enqueuedTaskIds,
      reason: routeResult.reason,
    );
  } catch (e, st) {
    _logger.warning('Failed to rerun downstream agents for $factId', e, st);
    return ReprocessDownstreamResult.failed(e.toString());
  }
}

List<String> _extractAssetPaths(
  FileSystemService fileSystem,
  String userId,
  String content,
) {
  final assetsDir = fileSystem.getAssetsPath(userId);
  return RegExp(r'fs://([^\s\)]+)').allMatches(content).map((m) {
    final filename = m.group(1)!;
    final absolutePath = '$assetsDir/$filename';
    return fileSystem.toRelativePath(absolutePath);
  }).toList();
}

/// Ensures the card exists; creates an initial card if not found.
Future<void> _ensureCardExists(
  FileSystemService fileSystem,
  String userId,
  String factId,
  DateTime? factDateTime,
) async {
  // Check whether the card exists.
  final existingCard = await fileSystem.readCardFile(userId, factId);
  if (existingCard != null) {
    // Card already exists; no need to create.
    return;
  }

  // Card not found; create initial card.
  _logger.info('Card not found for $factId, creating initial card');

  final now = factDateTime ?? DateTime.now();
  final initialCard = CardData(
    factId: factId,
    title: '',
    timestamp: now.millisecondsSinceEpoch ~/ 1000,
    status: 'processing',
    tags: const [],
    uiConfigs: const [UiConfig(templateId: 'classic_card', data: {})],
  );

  try {
    final success = await fileSystem.safeWriteCardFile(
      userId,
      factId,
      initialCard,
    );
    if (success) {
      _logger.info('Created initial card for: $factId');
    } else {
      _logger.warning('Failed to create initial card for: $factId');
    }
  } catch (e) {
    _logger.warning('Error creating initial card for $factId: $e');
    // Continue; let the subsequent flow handle the error.
  }
}

/// Saves progress to the task result.
Future<void> _saveProgress(
  String taskId,
  List<String> factIds,
  int currentIndex,
  int successCount,
  int failCount, {
  required ReprocessCardsDownstreamMode downstreamMode,
  required int downstreamAttemptedCount,
  required int downstreamSuccessCount,
  required int downstreamFailCount,
  required int downstreamSkippedCount,
  required int scheduleAggregationRequestedCount,
  required int downstreamTasksEnqueuedCount,
  required List<String> downstreamTaskIds,
  required Set<String> downstreamRerunFactIds,
  required ReprocessTaskResultWriter updateTaskResult,
}) async {
  final progress = {
    'factIds': factIds,
    'currentIndex': currentIndex,
    'successCount': successCount,
    'failCount': failCount,
    'total': factIds.length,
    'downstreamMode': downstreamMode.payloadValue,
    'downstreamAttemptedCount': downstreamAttemptedCount,
    'downstreamSuccessCount': downstreamSuccessCount,
    'downstreamFailCount': downstreamFailCount,
    'downstreamSkippedCount': downstreamSkippedCount,
    'scheduleAggregationRequestedCount': scheduleAggregationRequestedCount,
    'downstreamTasksEnqueuedCount': downstreamTasksEnqueuedCount,
    'downstreamTaskIds': downstreamTaskIds,
    'downstreamRerunFactIds': downstreamRerunFactIds.toList(),
  };

  final result = {
    'progress': progress,
    'success': successCount,
    'failed': failCount,
    'total': factIds.length,
    'downstream': _downstreamSummaryJson(
      downstreamMode: downstreamMode,
      attemptedCount: downstreamAttemptedCount,
      successCount: downstreamSuccessCount,
      failCount: downstreamFailCount,
      skippedCount: downstreamSkippedCount,
      scheduleAggregationRequestedCount: scheduleAggregationRequestedCount,
      tasksEnqueuedCount: downstreamTasksEnqueuedCount,
      taskIds: downstreamTaskIds,
    ),
  };

  await updateTaskResult(taskId, jsonEncode(result));
}

Map<String, dynamic> _downstreamSummaryJson({
  required ReprocessCardsDownstreamMode downstreamMode,
  required int attemptedCount,
  required int successCount,
  required int failCount,
  required int skippedCount,
  required int scheduleAggregationRequestedCount,
  required int tasksEnqueuedCount,
  required List<String> taskIds,
}) {
  return {
    'mode': downstreamMode.payloadValue,
    'attempted': attemptedCount,
    'succeeded': successCount,
    'failed': failCount,
    'skipped': skippedCount,
    'schedule_aggregation_requested': scheduleAggregationRequestedCount,
    'tasks_enqueued': tasksEnqueuedCount,
    if (taskIds.isNotEmpty) 'task_ids': taskIds,
    'schedule_item_changes': downstreamMode.rerunDownstream
        ? 'reported_by_schedule_aggregator_task'
        : 'not_requested',
    'system_action_changes': downstreamMode.rerunDownstream
        ? 'reported_by_schedule_aggregator_task'
        : 'not_requested',
  };
}
