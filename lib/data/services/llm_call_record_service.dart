import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:uuid/uuid.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/token_usage_utils.dart';
import 'file_system_service.dart';
import 'base_file_service.dart';

/// LLM call record service.
///
/// Records token usage and related info for all LLM calls.
/// Supports storage by scene (raw input, insight generation, discovery generation, etc.).
class LLMCallRecordService {
  final FileSystemService _fileSystem;
  final BaseFileService _baseService = BaseFileService();
  final Logger _logger = getLogger('LLMCallRecordService');
  final _lock = Lock();
  final _uuid = const Uuid();

  static LLMCallRecordService? _instance;
  static LLMCallRecordService get instance {
    _instance ??= LLMCallRecordService._();
    return _instance!;
  }

  LLMCallRecordService._() : _fileSystem = FileSystemService.instance;

  /// Returns the directory path for LLM call records.
  String _getLLMCallsPath(String userId) {
    return path.join(
        _fileSystem.getWorkspacePath(userId), '_System', 'llm_calls');
  }

  /// Ensures the directory exists, creating it if necessary.
  Future<void> _ensureDirectory(String dirPath) async {
    if (!await _baseService.exists(dirPath)) {
      final dir = Directory(dirPath);
      await dir.create(recursive: true);
    }
  }

  /// Records a single LLM call (invoked from StatefulAgent's afterLLMResponse callback).
  /// [state] must be passed in because the afterLLMResponse callback runs outside the tool-execution zone.
  ///
  /// ============================================================
  /// Why does AgentCallToolContext.current not work inside afterLLMResponse?
  /// ============================================================
  ///
  /// AgentCallToolContext is implemented via Dart's Zone mechanism and is only available
  /// within the specific execution context where tools run.
  ///
  /// StatefulAgent execution flow:
  /// 1. _runStream() main loop
  /// 2.   -> client.stream() calls the LLM
  /// 3.   -> aggregates response messages
  /// 4.   -> afterLLMResponse() callback ← [not inside a zone; current is null here]
  /// 5.   -> If there are function calls, execute tools:
  /// 6.     -> _executeTools()
  /// 7.       -> runZoned(() => tool.executable()) ← [inside zone here; current is available]
  /// 8.       -> tool execution completes, returns result
  /// 9.   -> continue loop or end
  ///
  /// Key points:
  /// - runZoned is only created when executing tools (see stateful_agent.dart lines 793-803)
  /// - afterLLMResponse is called at line 553, at which point we are not inside any runZoned
  /// - Hence AgentCallToolContext.current returns null inside afterLLMResponse
  ///
  /// ============================================================
  /// When can AgentCallToolContext.current be used?
  /// ============================================================
  ///
  /// ✅ Usable in:
  /// 1. Inside a Tool's executable function
  ///    - e.g. SaveCardTool.tool(), SaveTemplateTool.tool()
  ///    - e.g. UpdateCardInsight tool, file operation tools, etc.
  ///    - These run inside runZoned when the agent invokes the tool
  ///
  /// ❌ Not usable in:
  /// 1. afterLLMResponse callback (not inside a zone)
  /// 2. beforeCallLLM callback (not inside a zone)
  /// 3. beforeRunAgent / afterRunAgent callbacks (not inside a zone)
  /// 4. Handlers that call tools directly (e.g. analyze_assets_handler calling AssetAnalysisTool)
  ///    - because the handler is not in the agent's tool-execution context
  ///
  /// Workaround:
  /// - In callbacks: use the passed-in parameter (e.g. state) directly.
  /// - In handlers: pass userId and factId explicitly, or use instance.recordCall().
  static Future<void> recordAgentCall({
    required String scene,
    required String agentName,
    String? handlerName,
    required ModelMessage message,
    required AgentState state,
    Object? client,
  }) async {
    if (message.usage == null) {
      return; // No usage data, skip recording
    }

    final metadata = state.metadata;
    final userId = metadata['userId'] as String?;
    final factId = metadata['factId'] as String?;

    if (userId == null || factId == null) {
      return; // Missing required context, skip recording
    }

    await instance.recordCall(
      userId: userId,
      scene: scene,
      sceneId: factId,
      agentName: agentName,
      handlerName: handlerName,
      usage: message.usage!,
      model: message.model,
      client: client,
    );
  }

  /// Records a single LLM call.
  ///
  /// [userId] User ID.
  /// [scene] Scene type: 'input' (raw input), 'insight' (insight generation), 'discovery' (discovery generation), etc.
  /// [sceneId] Scene ID: fact_id, insight_id, discovery_id, etc.
  /// [agentName] Agent name, e.g. 'card_agent', 'pkm_agent'.
  /// [handlerName] Optional handler name, e.g. 'card_agent_handler'.
  /// [usage] Token usage for the call.
  /// [model] Model name.
  /// [metadata] Optional extra data (e.g. input/output, call time).
  Future<void> recordCall({
    required String userId,
    required String scene,
    required String sceneId,
    required String agentName,
    String? handlerName,
    required ModelUsage usage,
    required String model,
    Object? client,
    Map<String, dynamic>? metadata,
  }) async {
    return _lock.synchronized(() async {
      try {
        final callsDir = _getLLMCallsPath(userId);
        await _ensureDirectory(callsDir);

        // Generate a safe filename.
        final safeSceneId = _fileSystem.makeFactIdSafe(sceneId);
        final fileName = '${scene}_$safeSceneId.json';
        final filePath = path.join(callsDir, fileName);

        // Read existing record or create a new one.
        Map<String, dynamic> record;
        if (await _baseService.exists(filePath)) {
          try {
            final content = await _baseService.readFile(filePath);
            record = jsonDecode(content) as Map<String, dynamic>;
          } catch (e) {
            _logger.warning('Failed to parse existing LLM call record: $e');
            record = _createEmptyRecord(scene, sceneId);
          }
        } else {
          record = _createEmptyRecord(scene, sceneId);
        }

        // Resolve cache semantics from client + original usage.
        final cachedTokensIncludedInPrompt =
            TokenUsageUtils.cachedTokensIncludedInPrompt(
          client: client,
          originalUsage: usage.originalUsage,
        );

        // Append the new call to the record.
        final callId = _uuid.v4();
        final call = {
          'call_id': callId,
          'agent_name': agentName,
          if (handlerName != null) 'handler_name': handlerName,
          'timestamp': DateTime.now().microsecondsSinceEpoch,
          'model': model,
          'usage': {
            'prompt_tokens': usage.promptTokens,
            'completion_tokens': usage.completionTokens,
            'total_tokens': usage.totalTokens,
            if (usage.model != null) 'model': usage.model,
            'cached_tokens': usage.cachedToken,
            if (cachedTokensIncludedInPrompt != null)
              'cache_tokens_included_in_prompt': cachedTokensIncludedInPrompt,
            'thought_tokens': usage.thoughtToken,
            if (usage.originalUsage != null)
              'original_usage': usage.originalUsage,
          },
          if (metadata != null) 'metadata': metadata,
        };

        (record['calls'] as List).add(call);
        record['updated_at'] = DateTime.now().microsecondsSinceEpoch;

        // Persist to file.
        final jsonContent = jsonEncode(record);
        await _baseService.writeFile(filePath, jsonContent);

        _logger.fine('Recorded LLM call: $agentName for $scene/$sceneId');
      } catch (e, stack) {
        _logger.severe('Failed to record LLM call: $e', e, stack);
        // Do not rethrow; avoid affecting the main flow.
      }
    });
  }

  /// Creates an empty record structure.
  Map<String, dynamic> _createEmptyRecord(String scene, String sceneId) {
    return {
      'scene': scene,
      'scene_id': sceneId,
      'created_at': DateTime.now().microsecondsSinceEpoch,
      'updated_at': DateTime.now().microsecondsSinceEpoch,
      'calls': <Map<String, dynamic>>[],
    };
  }

  /// Returns the LLM call record for the given scene.
  Future<Map<String, dynamic>?> getRecord({
    required String userId,
    required String scene,
    required String sceneId,
  }) async {
    try {
      final callsDir = _getLLMCallsPath(userId);
      final safeSceneId = _fileSystem.makeFactIdSafe(sceneId);
      final fileName = '${scene}_$safeSceneId.json';
      final filePath = path.join(callsDir, fileName);

      if (!await _baseService.exists(filePath)) {
        return null;
      }

      final content = await _baseService.readFile(filePath);
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      _logger.warning('Failed to get LLM call record: $e');
      return null;
    }
  }

  /// Returns all LLM call records for the user (for aggregated statistics).
  ///
  /// [startDate] Optional start date filter.
  /// [endDate] Optional end date filter.
  /// [scene] Optional scene filter.
  Future<List<Map<String, dynamic>>> getAllRecords({
    required String userId,
    DateTime? startDate,
    DateTime? endDate,
    String? scene,
  }) async {
    try {
      final callsDir = _getLLMCallsPath(userId);
      if (!await _baseService.exists(callsDir)) {
        return [];
      }

      final files = await _baseService.listDirectory(callsDir);
      final records = <Map<String, dynamic>>[];

      for (final file in files) {
        if (!file.endsWith('.json')) continue;

        // Parse filename: scene_sceneId.json
        final parts = file.replaceAll('.json', '').split('_');
        if (parts.length < 2) continue;

        final fileScene = parts[0];
        if (scene != null && fileScene != scene) continue;

        final filePath = path.join(callsDir, file);
        try {
          final content = await _baseService.readFile(filePath);
          final record = jsonDecode(content) as Map<String, dynamic>;

          // Apply date filter.
          if (startDate != null || endDate != null) {
            final createdAt = DateTime.fromMicrosecondsSinceEpoch(
              record['created_at'] as int,
            );
            if (startDate != null && createdAt.isBefore(startDate)) continue;
            if (endDate != null && createdAt.isAfter(endDate)) continue;
          }

          records.add(record);
        } catch (e) {
          _logger.warning('Failed to parse record file $file: $e');
        }
      }

      return records;
    } catch (e) {
      _logger.warning('Failed to get all LLM call records: $e');
      return [];
    }
  }

  /// Returns aggregated statistics.
  ///
  /// Aggregates by day, month, agent, scene, etc.
  Future<Map<String, dynamic>> getAggregatedStatistics({
    required String userId,
    DateTime? startDate,
    DateTime? endDate,
    String? scene,
  }) async {
    final records = await getAllRecords(
      userId: userId,
      startDate: startDate,
      endDate: endDate,
      scene: scene,
    );

    final dailyStats = <String, Map<String, dynamic>>{};
    final monthlyStats = <String, Map<String, dynamic>>{};
    final agentStats = <String, Map<String, dynamic>>{};
    final sceneStats = <String, Map<String, dynamic>>{};

    int totalCalls = 0;
    int totalPromptTokens = 0;
    int totalCompletionTokens = 0;
    int totalCachedTokens = 0;
    int totalEffectivePromptTokens = 0;
    int totalCachedForRate = 0;
    int totalThoughtTokens = 0;
    int totalTokens = 0;

    // Aggregate directly from the calls in each record.
    for (final record in records) {
      final calls = record['calls'] as List? ?? [];
      final sceneType = record['scene'] as String;

      for (final call in calls) {
        final usage = call['usage'] as Map<String, dynamic>;
        final promptTokens = usage['prompt_tokens'] as int? ?? 0;
        final completionTokens = usage['completion_tokens'] as int? ?? 0;
        final cachedTokens = usage['cached_tokens'] as int? ?? 0;
        final sem = TokenUsageUtils.resolveFromUsageRecord(usage);
        final effPrompt = TokenUsageUtils.effectivePromptTokensOrNull(
            promptTokens: promptTokens,
            cachedTokens: cachedTokens,
            cachedTokensIncludedInPrompt: sem);
        final thoughtTokens = usage['thought_tokens'] as int? ?? 0;
        final tokens = usage['total_tokens'] as int? ?? 0;
        final agentName = call['agent_name'] as String;
        final timestamp = call['timestamp'] as int?;
        final callCreatedAt = timestamp != null
            ? DateTime.fromMicrosecondsSinceEpoch(timestamp)
            : DateTime.fromMicrosecondsSinceEpoch(record['created_at'] as int);

        // Helper to create empty stat bucket.
        Map<String, dynamic> emptyStat() => {
              'calls': 0,
              'prompt_tokens': 0,
              'completion_tokens': 0,
              'cached_tokens': 0,
              'effective_prompt_tokens': 0,
              'cached_tokens_for_rate': 0,
              'thought_tokens': 0,
              'total_tokens': 0,
            };

        // Helper to accumulate into a stat bucket.
        void accumulate(Map<String, dynamic> stat) {
          stat['calls'] = (stat['calls'] as int) + 1;
          stat['prompt_tokens'] = (stat['prompt_tokens'] as int) + promptTokens;
          stat['completion_tokens'] =
              (stat['completion_tokens'] as int) + completionTokens;
          stat['cached_tokens'] = (stat['cached_tokens'] as int) + cachedTokens;
          if (effPrompt != null) {
            stat['effective_prompt_tokens'] =
                (stat['effective_prompt_tokens'] as int) + effPrompt;
            stat['cached_tokens_for_rate'] =
                (stat['cached_tokens_for_rate'] as int) + cachedTokens;
          }
          stat['thought_tokens'] =
              (stat['thought_tokens'] as int) + thoughtTokens;
          stat['total_tokens'] = (stat['total_tokens'] as int) + tokens;
        }

        // Aggregate by day.
        final dayKey =
            '${callCreatedAt.year}-${callCreatedAt.month.toString().padLeft(2, '0')}-${callCreatedAt.day.toString().padLeft(2, '0')}';
        dailyStats.putIfAbsent(dayKey, emptyStat);
        accumulate(dailyStats[dayKey]!);

        // Aggregate by month.
        final monthKey =
            '${callCreatedAt.year}-${callCreatedAt.month.toString().padLeft(2, '0')}';
        monthlyStats.putIfAbsent(monthKey, emptyStat);
        accumulate(monthlyStats[monthKey]!);

        // Aggregate by scene.
        sceneStats.putIfAbsent(sceneType, emptyStat);
        accumulate(sceneStats[sceneType]!);

        // Aggregate by agent.
        agentStats.putIfAbsent(agentName, emptyStat);
        accumulate(agentStats[agentName]!);

        // Totals.
        totalCalls++;
        totalPromptTokens += promptTokens;
        totalCompletionTokens += completionTokens;
        totalCachedTokens += cachedTokens;
        if (effPrompt != null) {
          totalEffectivePromptTokens += effPrompt;
          totalCachedForRate += cachedTokens;
        }
        totalThoughtTokens += thoughtTokens;
        totalTokens += tokens;
      }
    }

    return {
      'total': {
        'calls': totalCalls,
        'prompt_tokens': totalPromptTokens,
        'completion_tokens': totalCompletionTokens,
        'cached_tokens': totalCachedTokens,
        'effective_prompt_tokens': totalEffectivePromptTokens,
        'cached_tokens_for_rate': totalCachedForRate,
        'thought_tokens': totalThoughtTokens,
        'total_tokens': totalTokens,
      },
      'by_day': dailyStats,
      'by_month': monthlyStats,
      'by_agent': agentStats,
      'by_scene': sceneStats,
    };
  }
}
