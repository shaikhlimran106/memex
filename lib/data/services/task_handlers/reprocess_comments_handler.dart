import 'dart:convert';
import 'dart:math'; // Import Random

import 'package:logging/logging.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/domain/models/character_model.dart'; // Import CharacterModel
import 'package:memex/data/services/character_service.dart'; // Import CharacterService
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/repositories/post_comment.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/data/services/task_handlers/llm_error_utils.dart';
import 'package:memex/utils/logger.dart';

final Logger _logger = getLogger('ReprocessCommentsHandler');

/// Number of cards to process per batch (concurrently).
const int _batchSize =
    1; // Process serially to avoid race conditions and overload

/// Task Handler implementation for `reprocess_comments_task`.
///
/// Supports resuming from where the previous run left off.
Future<void> handleReprocessCommentsImpl(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
) async {
  _logger.info('Starting reprocess comments task for user: $userId');

  try {
    // 1. Get or restore progress.
    Map<String, dynamic>? progress;
    try {
      final existingResult =
          await LocalTaskExecutor.instance.getTaskResult(context.taskId);
      if (existingResult != null && existingResult.containsKey('progress')) {
        progress = existingResult['progress'] as Map<String, dynamic>;
        _logger.info(
            'Resuming from progress: ${progress['currentIndex']}/${progress['total']}');
      }
    } catch (e) {
      _logger.warning('Failed to retrieve progress: $e');
    }

    // 2. Get the fact list to process.
    List<String> factIds;
    int currentIndex;
    int successCount;
    int failCount;

    if (progress != null) {
      // Restore from saved progress.
      final rawFactIds = progress['factIds'] as List;
      factIds = rawFactIds.map((e) => e.toString()).toList();
      currentIndex = progress['currentIndex'] as int;
      successCount = progress['successCount'] as int? ?? 0;
      failCount = progress['failCount'] as int? ?? 0;
      _logger.info('Resuming from index $currentIndex');
    } else {
      // First run: build fact list.
      final fileSystem = FileSystemService.instance;

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

      // List all cards.
      _logger.info('Listing all cards...');
      final cardPaths = await fileSystem.listAllCardFiles(userId);
      final allFactIds = cardPaths
          .map(fileSystem.factIdFromCardPath)
          .whereType<String>()
          .toList();
      _logger.info('Found ${allFactIds.length} cards');

      // filter facts
      factIds = <String>[];
      for (final factId in allFactIds) {
        try {
          final factDate = fileSystem.parseFactIdDate(factId);
          final cardDate =
              DateTime(factDate.year, factDate.month, factDate.day);

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
      );
    }

    final total = factIds.length;
    _logger.info(
        'Processing ${total - currentIndex} cards (starting from index $currentIndex), batch size: $_batchSize');

    // Get user content prompt once.
    final userContent = Prompts.commentAgentInitialCommentPrompt;

    // Get enabled characters once
    final characters = await CharacterService.instance.getAllCharacters(userId);
    final enabledCharacters = characters.where((c) => c.enabled).toList();

    if (enabledCharacters.isEmpty) {
      _logger
          .warning("No enabled characters, skipping reprocess comments task");
      // Mark as completed but failed count? Or just return?
      // Since we can't do anything without characters (based on logic), we should probably stop.
      // But we need to save result.
      // Let's assume failCount = remaining.
    }

    // 3. Process in batches.
    while (currentIndex < factIds.length) {
      // Check if we have characters inside the loop or break before?
      if (enabledCharacters.isEmpty) {
        break; // Stop processing
      }
      final endIndex = (currentIndex + _batchSize).clamp(0, total);
      final batch = factIds.sublist(currentIndex, endIndex);
      final batchNumber = currentIndex ~/ _batchSize + 1;
      final totalBatches = (total + _batchSize - 1) ~/ _batchSize;

      _logger.info(
          'Processing batch $batchNumber/$totalBatches: cards ${currentIndex + 1}-$endIndex of $total');

      final results = await Future.wait(
        batch.map((factId) => _processOneCardComment(
            userId, factId, userContent, enabledCharacters)),
      );

      for (var i = 0; i < results.length; i++) {
        if (results[i]) {
          successCount++;
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
      );
    }

    // 4. Save final result.
    final result = {
      'success': successCount,
      'failed': failCount,
      'total': total,
      'completed': true,
    };

    await LocalTaskExecutor.instance.updateTaskResult(
      context.taskId,
      jsonEncode(result),
    );

    _logger.info(
        'Reprocess comments task completed. Success: $successCount, Failed: $failCount, Total: $total');
  } catch (e, stack) {
    _logger.severe('Error in reprocess comments task: $e', e, stack);
    rethrowIfNonRetryable(e);
  }
}

/// Processes a single card: calls processAICommentReply.
Future<bool> _processOneCardComment(
  String userId,
  String factId,
  String userContent,
  List<CharacterModel> enabledCharacters,
) async {
  try {
    // 1. Read card source content.
    final fileSystem = FileSystemService.instance;
    final card = await fileSystem.readCardFile(userId, factId);

    if (card == null || card.deleted == true) {
      _logger.warning('Card not found for comment reprocess: $factId');
      return false;
    }

    final rawInputContent = card.fact?.trim();
    if (rawInputContent == null || rawInputContent.isEmpty) {
      _logger
          .warning('Card has no fact content for comment reprocess: $factId');
      return false;
    }

    // 2. Character Selection (Deterministic)
    // Matches logic in handleCommentAgentImpl
    final seed = factId.hashCode;
    final rng = Random(seed);
    final selectedChar =
        enabledCharacters[rng.nextInt(enabledCharacters.length)];
    final selectedCharId = selectedChar.id;

    // Call processAICommentReply
    await processAICommentReply(
      cardId: factId,
      userId: userId,
      userContent: userContent,
      characterId: selectedCharId,
      rawInputContent: rawInputContent,
      sendEventBus: false,
      inputDateTime: DateTime.fromMillisecondsSinceEpoch(
        (card.createdAt ?? card.timestamp) * 1000,
      ),
    );

    return true;
  } catch (e, stack) {
    _logger.severe(
        'Failed to reprocess comment for card $factId: $e', e, stack);
    return false;
  }
}

/// Saves progress to the task result.
Future<void> _saveProgress(
  String taskId,
  List<String> factIds,
  int currentIndex,
  int successCount,
  int failCount,
) async {
  final progress = {
    'factIds': factIds,
    'currentIndex': currentIndex,
    'successCount': successCount,
    'failCount': failCount,
    'total': factIds.length,
  };

  final result = {
    'progress': progress,
    'success': successCount,
    'failed': failCount,
    'total': factIds.length,
  };

  await LocalTaskExecutor.instance.updateTaskResult(
    taskId,
    jsonEncode(result),
  );
}
