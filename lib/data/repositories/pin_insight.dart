import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:memex/data/services/file_system_service.dart';

final _logger = getLogger('PinInsightEndpoint');
FileSystemService get _fileSystemService => FileSystemService.instance;

/// Pin Knowledge Insight card
///
/// Args:
///   cardId: card ID (filename, no path, may have suffix)
///
/// Returns:
///   bool: success
Future<bool> pinInsightEndpoint(String cardId) async {
  _logger.info('PinInsightEndpoint: pinInsight called: cardId=$cardId');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw Exception('User not logged in, cannot pin insight');
    }

    final data =
        await _fileSystemService.readKnowledgeInsightCard(userId, cardId);
    if (data == null) {
      _logger.warning('Card not found for pinning: $cardId');
      return false;
    }

    if (data['pinned'] == true) {
      return true; // already pinned
    }

    data['pinned'] = true;
    data['updated_at'] = DateTime.now().toIso8601String();

    // Ensure id exists
    if (!data.containsKey('id')) {
      data['id'] = cardId.endsWith('.yaml')
          ? cardId.substring(0, cardId.length - 5)
          : cardId;
    }

    await _fileSystemService.writeKnowledgeInsightCard(userId, cardId, data);
    _logger.info('Pinned card for user $userId: $cardId');

    // Log event
    try {
      final cardPath = 'KnowledgeInsights/Cards/$cardId.yaml';
      await _fileSystemService.eventLogService.logEvent(
        userId: userId,
        eventType: 'user_action',
        description: 'User pinned knowledge insight card',
        filePath: cardPath,
        metadata: {
          'action': 'pin',
          'card_id': cardId,
          'title': data['title'],
        },
      );
    } catch (e) {
      _logger.warning('Failed to log pin event: $e');
    }

    return true;
  } catch (e) {
    _logger.severe('Failed to pin insight $cardId: $e');
    return false;
  }
}

/// Unpin Knowledge Insight card
///
/// Args:
///   cardId: card ID
///
/// Returns:
///   bool: success
Future<bool> unpinInsightEndpoint(String cardId) async {
  _logger.info('PinInsightEndpoint: unpinInsight called: cardId=$cardId');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw Exception('User not logged in, cannot unpin insight');
    }

    final data =
        await _fileSystemService.readKnowledgeInsightCard(userId, cardId);
    if (data == null) {
      _logger.warning('Card not found for unpinning: $cardId');
      return false;
    }

    if (data['pinned'] != true) {
      return true; // already unpinned
    }

    data['pinned'] = false;
    data['updated_at'] = DateTime.now().toIso8601String();

    await _fileSystemService.writeKnowledgeInsightCard(userId, cardId, data);
    _logger.info('Unpinned card for user $userId: $cardId');

    // Log event
    try {
      final cardPath = 'KnowledgeInsights/Cards/$cardId.yaml';
      await _fileSystemService.eventLogService.logEvent(
        userId: userId,
        eventType: 'user_action',
        description: 'User unpinned knowledge insight card',
        filePath: cardPath,
        metadata: {
          'action': 'unpin',
          'card_id': cardId,
          'title': data['title'],
        },
      );
    } catch (e) {
      _logger.warning('Failed to log unpin event: $e');
    }

    return true;
  } catch (e) {
    _logger.severe('Failed to unpin insight $cardId: $e');
    return false;
  }
}
