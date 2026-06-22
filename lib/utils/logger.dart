import 'package:logging/logging.dart';
import 'package:flutter/foundation.dart';
import 'package:memex/data/services/file_logger_service.dart';

bool _isLoggerSetup = false;

/// Initialize the logger configuration
Future<void> setupLogger() async {
  if (_isLoggerSetup) return;
  _isLoggerSetup = true;

  // initialize file logger
  await FileLoggerService.instance.initialize();

  Logger.root.level = Level.ALL; // Defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // Write filelog
    FileLoggerService.instance.writeLog(record);

    // also print to console in debug mode
    if (kDebugMode) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    }
  });
}

/// Convenience to get a Logger instance
Logger getLogger(String name) {
  return Logger(name);
}
