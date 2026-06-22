import 'dart:io';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:memex/agent/memory_agent/memory_agent.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/time_context.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as path;

class _UserSyncState {
  final List<String> pendingFactIds = [];
  bool isProcessing = false;
  bool isLoaded = false;
}

class MemorySyncService {
  static final MemorySyncService _instance = MemorySyncService._internal();
  static MemorySyncService get instance => _instance;

  final Logger _logger = Logger('MemorySyncService');

  MemorySyncService._internal();

  // State management per user
  final Map<String, _UserSyncState> _userStates = {};
  static const int _batchThreshold = 5;

  _UserSyncState _getState(String userId) {
    return _userStates.putIfAbsent(userId, () => _UserSyncState());
  }

  /// Handles a single memory sync task by accumulating fact IDs.
  /// When the batch threshold is reached, triggers asynchronous processing.
  Future<void> enqueueFact(String userId, String factId) async {
    final state = _getState(userId);

    // Load pending facts if this is the first call for this user
    if (!state.isLoaded) {
      await _loadPendingFactIds(userId);
      state.isLoaded = true;
    }

    state.pendingFactIds.add(factId);
    _logger.info(
        'Added fact $factId to memory sync queue for user $userId. Queue size: ${state.pendingFactIds.length}');

    // Persist after adding
    await _savePendingFactIds(userId);

    // Trigger processing if threshold reached and not already processing
    if (!state.isProcessing && state.pendingFactIds.length >= _batchThreshold) {
      _logger.info(
          'Batch threshold reached for user $userId. Triggering async processing.');
      // Start processing in background (fire and forget)
      _processQueue(userId);
    }
  }

  /// Processes pending facts in the queue asynchronously.
  /// Handles concurrency using `isProcessing` flag per user.
  Future<void> _processQueue(String userId) async {
    final state = _getState(userId);
    if (state.isProcessing) return;

    state.isProcessing = true;

    try {
      AgentActivityService.instance.pushMessage(
        type: AgentActivityType.agent_start,
        title: 'Syncing User Memories',
        icon: '🧠',
        agentName: 'memory_sync_service',
        agentId: 'memory_sync',
        userId: userId,
      );

      while (state.pendingFactIds.isNotEmpty) {
        // Take a snapshot of the current batch
        final batch = List<String>.from(state.pendingFactIds);

        _logger.info(
            'Processing batch of ${batch.length} facts for user $userId...');

        final facts = <Map<String, dynamic>>[];
        final fileSystem = FileSystemService.instance;

        for (final factId in batch) {
          // The card's own `fact` field is the source-of-truth user input
          // (text + meaningful attachment content). Cards created through
          // SuperAgent have no Facts file, so read the card directly.
          final card = await fileSystem.readCardFile(userId, factId);
          final factText = card?.fact?.trim() ?? '';
          if (card == null || factText.isEmpty) {
            _logger.warning('No card.fact to sync for: $factId');
            continue;
          }

          final contentBuffer = StringBuffer();
          contentBuffer.writeln("<user_fact>");
          contentBuffer.writeln('ID: $factId');
          if (card.timestamp > 0) {
            contentBuffer.writeln(
                "Published Time: ${formatLocalDateTimeWithZone(DateTime.fromMillisecondsSinceEpoch(card.timestamp * 1000))}");
          }
          contentBuffer.writeln('User Original Content:');
          contentBuffer.writeln(factText);
          contentBuffer.writeln("</user_fact>");

          facts.add({
            'id': factId,
            'content': contentBuffer.toString(),
          });
        }

        if (facts.isNotEmpty) {
          await _processBatch(userId, facts);
        }

        // Only clear successfully processed items from the queue
        // Since we are single-threaded (mostly), and only append to end,
        // removing the first N items (batch.length) is safe.
        // If newer items were added during processing, they remain at the end.
        if (batch.length <= state.pendingFactIds.length) {
          state.pendingFactIds.removeRange(0, batch.length);
        } else {
          // Should not happen unless list was modified unexpectedly
          state.pendingFactIds.clear();
        }

        await _savePendingFactIds(userId);

        _logger.info(
            'Successfully processed batch for user $userId. Remaining queue size: ${state.pendingFactIds.length}');
      }
    } catch (e, stack) {
      _logger.severe(
          'Failed to process memory sync batch for user $userId', e, stack);
      // Stop processing loop on error. Failed items remain in queue.
      // Next time enqueueFact triggers, it will retry.
    } finally {
      AgentActivityService.instance.pushMessage(
        type: AgentActivityType.agent_stop,
        title: 'Memory Sync Completed',
        icon: '✅',
        agentName: 'memory_sync_service',
        agentId: 'memory_sync',
        userId: userId,
      );
      state.isProcessing = false;
    }
  }

  /// Calls MemoryAgent to process the batch
  Future<void> _processBatch(
      String userId, List<Map<String, dynamic>> batch) async {
    // 1. Prepare Content Buffer
    final buffer = StringBuffer();

    // Add global context about the data structure
    buffer.writeln("## Data Structure Definition");
    buffer.writeln("Each item in <user_facts> contains:");
    buffer.writeln(
        "'User Original Content': the source-of-truth record for this user — the user's own text plus the meaningful content of any attachments they captured. Base memory extraction on this.");
    buffer.writeln("");

    buffer.writeln("## User Facts");
    buffer.writeln("<user_facts>");
    for (final fact in batch) {
      buffer.writeln(fact['content']);
    }
    buffer.writeln("</user_facts>");

    // 2. Get LLM Resources
    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.profileAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );

    // 3. Run Memory Agent
    await MemoryAgent.run(
      client: resources.client,
      modelConfig: resources.modelConfig,
      userId: userId,
      bufferedContent: buffer.toString(),
    );
  }

  /// Loads pending fact IDs from disk
  Future<void> _loadPendingFactIds(String userId) async {
    try {
      final fileService = FileSystemService.instance;
      final systemPath = fileService.getSystemPath(userId);
      final memoryDir = path.join(systemPath, 'memory');
      final pendingFile =
          File(path.join(memoryDir, 'memory_sync_pending.json'));

      // Use state directly instead of clearing instance variable
      final state = _getState(userId);

      if (await pendingFile.exists()) {
        final content = await pendingFile.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        state.pendingFactIds.clear();
        state.pendingFactIds.addAll(jsonList.cast<String>());
        _logger.info(
            'Loaded ${state.pendingFactIds.length} pending facts for user $userId');
      } else {
        state.pendingFactIds.clear(); // Ensure empty valid state
      }
    } catch (e) {
      _logger.severe('Failed to load pending fact IDs for user $userId', e);
      // Ensure we start fresh on error to avoid infinite loop
      _getState(userId).pendingFactIds.clear();
    }
  }

  /// Saves pending fact IDs to disk
  Future<void> _savePendingFactIds(String userId) async {
    try {
      final fileService = FileSystemService.instance;
      final systemPath = fileService.getSystemPath(userId);
      final memoryDir = path.join(systemPath, 'memory');
      final pendingFile =
          File(path.join(memoryDir, 'memory_sync_pending.json'));

      if (!await pendingFile.parent.exists()) {
        await pendingFile.parent.create(recursive: true);
      }

      final state = _getState(userId);
      await pendingFile.writeAsString(jsonEncode(state.pendingFactIds));
    } catch (e) {
      _logger.severe('Failed to save pending fact IDs for user $userId', e);
    }
  }
}
