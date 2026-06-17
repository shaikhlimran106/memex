import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/search_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/time_context.dart';
import 'package:memex/utils/user_storage.dart';

final _logger = getLogger('TimelineDiagnosticsSkill');

/// Focused Timeline/Card lookup tools for Super Agent.
///
/// This skill helps the agent find a card and inspect the exact local state
/// needed to repair it through manage_timeline_card. It does not retry or
/// mutate cards directly.
class TimelineDiagnosticsSkill extends Skill {
  TimelineDiagnosticsSkill()
      : super(
          name: 'timeline_diagnostics',
          description:
              'Finds and inspects Memex Timeline cards. Use when the user refers to an existing card, a past record, or a failed/wrong Timeline card that may need repair.',
          systemPrompt: _buildSystemPrompt(),
          tools: _buildTools(),
        );

  static String _buildSystemPrompt() {
    return '''
# Timeline Diagnostics Skill

Use this skill to find an existing Timeline card and inspect its current local state.

Tool policy:
- Use `search_timeline_cards` when the user describes a past card but does not provide a card id. Omit query to list recent cards.
- Use `inspect_timeline_card` once you know the target card id.
- These tools are read-only. Do not claim they fixed anything.
- If a card needs repair, use `manage_timeline_card` with the inspected original input and current CardData state.
- Do not use this skill for template design. Use `dynamic_timeline_ui` only after `manage_timeline_card` is active and a template change is actually needed.
''';
  }

  static List<Tool> _buildTools() {
    return [
      Tool(
        name: 'search_timeline_cards',
        description:
            'Search past Timeline cards by full-text match, or list recent cards when query is omitted. Returns card ids, local creation time, and content snippets.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Optional search query for the card title/content full-text index. Omit to return recent cards.',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'Maximum number of results to return. Defaults to 10, max 30.',
            },
          },
        },
        executable: (Map<String, dynamic> args) async {
          final query = args['query']?.toString().trim();
          final limit = _intArg(args['limit'], fallback: 10, min: 1, max: 30);
          return searchTimelineCards(
            query: query,
            limit: limit,
          );
        },
      ),
      Tool(
        name: 'inspect_timeline_card',
        description:
            'Inspect one Timeline card by card_id/fact_id. Returns the original input context and current CardData state excluding comments.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Timeline card id / fact id, for example 2026/06/10.md#ts_3.',
            },
          },
          'required': ['card_id'],
        },
        executable: (Map<String, dynamic> args) async {
          final userId = await _resolveUserId();
          final cardId = _requiredString(args, 'card_id');
          return inspectTimelineCardForUser(
            userId: userId,
            cardId: cardId,
          );
        },
      ),
    ];
  }

  static Future<String> searchTimelineCards({
    String? query,
    int limit = 10,
    String? userId,
  }) async {
    final safeLimit = limit.clamp(1, 30).toInt();
    final resolvedUserId = userId ?? await _resolveUserId();
    final trimmedQuery = query?.trim() ?? '';
    final formattedResults = trimmedQuery.isEmpty
        ? await _recentTimelineCardResults(
            userId: resolvedUserId,
            limit: safeLimit,
          )
        : await _searchTimelineCardResults(
            userId: resolvedUserId,
            query: trimmedQuery,
            limit: safeLimit,
          );

    return _formatSearchResults(
      query: trimmedQuery.isEmpty ? null : trimmedQuery,
      results: formattedResults,
    );
  }

  static Future<String> inspectTimelineCardForUser({
    required String userId,
    required String cardId,
  }) async {
    final card = await _safeReadCard(userId, cardId);
    if (card == null) {
      return 'Card not found.';
    }

    return _formatCardInspection(
      originalInputContext: _buildOriginalInputContext(card),
      currentCardData: _cardDataWithoutComments(card),
    );
  }

  static String? _buildOriginalInputContext(CardData card) {
    final fact = card.fact?.trim() ?? '';
    final hasFact = fact.isNotEmpty;
    final hasAssets = card.assets.isNotEmpty;
    if (!hasFact && !hasAssets) {
      return null;
    }

    final buffer = StringBuffer();
    if (card.timestamp > 0) {
      buffer.writeln(
        'Published time: ${formatLocalDateTimeWithZone(dateTimeFromUnixSeconds(card.timestamp))}',
      );
    }
    buffer
      ..writeln('Original user input (fact):')
      ..writeln(hasFact ? fact : '(none)');
    if (hasAssets) {
      buffer.writeln('Associated media files:');
      for (final ref in card.assets) {
        buffer.writeln('- $ref');
      }
    }
    return buffer.toString().trimRight();
  }

  static Map<String, dynamic> _cardDataWithoutComments(CardData card) {
    final data = card.toJson();
    data.remove('comments');
    return data;
  }

  static Future<String?> _createdAtLocalForCard({
    required String userId,
    required String cardId,
  }) async {
    if (cardId.isEmpty) return null;
    final card = await _safeReadCard(userId, cardId);
    final timestamp = card?.timestamp;
    if (timestamp == null || timestamp <= 0) {
      return null;
    }
    return formatLocalDateTimeWithZone(dateTimeFromUnixSeconds(timestamp));
  }

  static Future<List<Map<String, dynamic>>> _searchTimelineCardResults({
    required String userId,
    required String query,
    required int limit,
  }) async {
    final results = await SearchService.instance.searchCards(
      query,
      limit: limit,
    );
    final formattedResults = <Map<String, dynamic>>[];
    for (final result in results) {
      final cardId = result['fact_id']?.toString() ?? '';
      formattedResults.add({
        'card_id': cardId,
        'created_at_local': await _createdAtLocalForCard(
          userId: userId,
          cardId: cardId,
        ),
        'content_snippet': _stripSnippetMarkup(
          result['content_snippet']?.toString() ?? '',
        ),
      });
    }
    return formattedResults;
  }

  static Future<List<Map<String, dynamic>>> _recentTimelineCardResults({
    required String userId,
    required int limit,
  }) async {
    final fs = FileSystemService.instance;
    final cardFiles = await fs.listAllCardFiles(userId);
    final results = <Map<String, dynamic>>[];

    for (final cardFile in cardFiles) {
      if (results.length >= limit) break;
      final cardId = fs.factIdFromCardPath(cardFile);
      if (cardId == null) continue;
      final card = await _safeReadCard(userId, cardId);
      if (card == null || card.deleted == true) continue;
      results.add(_cardSearchResult(card));
    }

    return results;
  }

  static Map<String, dynamic> _cardSearchResult(CardData card) {
    return {
      'card_id': card.factId,
      'created_at_local': card.timestamp > 0
          ? formatLocalDateTimeWithZone(dateTimeFromUnixSeconds(card.timestamp))
          : null,
      'content_snippet': _cardSnippet(card),
    };
  }

  static String _cardSnippet(CardData card) {
    final parts = <String>[
      if (card.title != null && card.title!.trim().isNotEmpty)
        card.title!.trim(),
      ...card.uiConfigs
          .expand((config) => config.data.values)
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    ];
    final joined = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (joined.length <= 160) return joined;
    return '${joined.substring(0, 160)}...';
  }

  static String _formatSearchResults({
    required String? query,
    required List<Map<String, dynamic>> results,
  }) {
    if (results.isEmpty) {
      return query == null
          ? 'No recent timeline cards found.'
          : 'No timeline cards found.';
    }

    final buffer = StringBuffer();
    buffer.writeln(query == null
        ? 'Recent timeline cards:'
        : 'Timeline card search results:');
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      buffer
        ..writeln('${i + 1}. ${result['card_id']}')
        ..writeln('   Created: ${result['created_at_local'] ?? 'unknown'}');
      final snippet = result['content_snippet']?.toString().trim() ?? '';
      if (snippet.isNotEmpty) {
        buffer.writeln('   Snippet: $snippet');
      }
    }
    return buffer.toString().trimRight();
  }

  static String _formatCardInspection({
    required String? originalInputContext,
    required Map<String, dynamic> currentCardData,
  }) {
    final buffer = StringBuffer()..writeln('Original input context:');
    if (originalInputContext == null || originalInputContext.trim().isEmpty) {
      buffer.writeln('Unavailable.');
    } else {
      buffer.writeln(originalInputContext);
    }

    buffer
      ..writeln('')
      ..writeln('Current CardData:');
    _writeKeyValues(buffer, currentCardData);
    return buffer.toString().trimRight();
  }

  static void _writeKeyValues(
    StringBuffer buffer,
    Map<String, dynamic> values,
  ) {
    for (final entry in values.entries) {
      buffer.writeln('${entry.key}: ${_formatValue(entry.value)}');
    }
  }

  static String _formatValue(dynamic value) {
    if (value == null) return 'null';
    if (value is List) {
      if (value.isEmpty) return '[]';
      return value.map(_formatValue).join(', ');
    }
    if (value is Map) {
      if (value.isEmpty) return '{}';
      return value.entries
          .map((entry) => '${entry.key}: ${_formatValue(entry.value)}')
          .join('; ');
    }
    return value.toString();
  }

  static Future<String?> createdAtLocalForCardForTesting({
    required String userId,
    required String cardId,
  }) {
    return _createdAtLocalForCard(userId: userId, cardId: cardId);
  }

  static Future<CardData?> _safeReadCard(String userId, String cardId) async {
    try {
      return await FileSystemService.instance.readCardFile(userId, cardId);
    } catch (e, stackTrace) {
      _logger.warning('Failed to read card $cardId', e, stackTrace);
      return null;
    }
  }

  static Future<String> _resolveUserId() async {
    final contextUserId =
        AgentCallToolContext.current?.state.metadata['userId']?.toString();
    if (contextUserId != null && contextUserId.trim().isNotEmpty) {
      return contextUserId.trim();
    }
    final userId = await UserStorage.getUserId();
    if (userId == null || userId.trim().isEmpty) {
      throw StateError('User not logged in, cannot inspect Timeline data.');
    }
    return userId.trim();
  }

  static String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value;
  }

  static int _intArg(
    dynamic value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return (parsed ?? fallback).clamp(min, max).toInt();
  }

  static String _stripSnippetMarkup(String value) {
    return value.replaceAll('<b>', '').replaceAll('</b>', '');
  }
}
