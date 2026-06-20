import 'dart:async';

import 'package:logging/logging.dart';

class SqliteBusyRetry {
  const SqliteBusyRetry._();

  static bool isDatabaseLocked(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('sqliteexception(5)') ||
        message.contains('database_busy') ||
        message.contains('code 5');
  }

  static Future<T> run<T>({
    required String operation,
    required Logger logger,
    required Future<T> Function() action,
    int maxAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 120),
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } catch (error, stackTrace) {
        if (!isDatabaseLocked(error) || attempt == maxAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        logger.info(
          'SQLite database locked during $operation '
          '(attempt $attempt/$maxAttempts); retrying.',
        );
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
    throw StateError('unreachable SQLite retry path');
  }
}
