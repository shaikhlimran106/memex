import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'package:memex/utils/logger.dart';

/// Service for last publish timestamp
class PublishTimestampService {
  static const String _keyLastPublishTimestamp = 'last_publish_timestamp';
  static final Logger _logger = getLogger('PublishTimestampService');

  /// Get last publish timestamp (milliseconds)
  static Future<int?> getLastPublishTimestamp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt(_keyLastPublishTimestamp);
      return timestamp;
    } catch (e) {
      return null;
    }
  }

  /// Save last publish timestamp
  static Future<void> saveLastPublishTimestamp(int timestamp) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyLastPublishTimestamp, timestamp);
    } catch (e) {
      // ignore error
    }
  }

  /// Get query timestamp for new images (max of last publish and 24h ago)
  static Future<int> getQueryTimestamp() async {
    final lastPublish = await getLastPublishTimestamp();
    final now = DateTime.now();
    final twentyFourHoursAgo = now.subtract(const Duration(hours: 24));
    final twentyFourHoursAgoTimestamp =
        twentyFourHoursAgo.millisecondsSinceEpoch;

    _logger.info('Last publish timestamp: $lastPublish');
    _logger.info('24h ago timestamp: $twentyFourHoursAgoTimestamp');
    _logger.info('24h ago time: $twentyFourHoursAgo');

    if (lastPublish == null) {
      _logger.info('No last publish time, using 24h ago timestamp');
      return twentyFourHoursAgoTimestamp;
    }

    // Return max of the two
    final result = lastPublish > twentyFourHoursAgoTimestamp
        ? lastPublish
        : twentyFourHoursAgoTimestamp;
    _logger.info(
        'Final query timestamp: $result (${lastPublish > twentyFourHoursAgoTimestamp ? "using last publish time" : "using 24h ago"})');
    return result;
  }
}
