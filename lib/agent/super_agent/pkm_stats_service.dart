import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:path/path.dart' as p;

class PkmStatsService {
  static final Logger _logger = getLogger('PkmStatsService');
  static const String _statsFileName = 'pkm_stats.json';
  static const int _maxHistorySize = 5;

  static final PkmStatsService _instance = PkmStatsService._internal();
  static PkmStatsService get instance => _instance;

  PkmStatsService._internal();

  Future<void> recordSessionEdits(
      String userId, List<String> editedFiles) async {
    final statsFile = _getStatsFile(userId);
    Map<String, dynamic> stats = {};

    if (statsFile.existsSync()) {
      try {
        final content = await statsFile.readAsString();
        stats = jsonDecode(content);
      } catch (e) {
        _logger.warning('Failed to read stats file: $e');
      }
    }

    var recentSessions = <dynamic>[];
    if (stats.containsKey('recent_sessions')) {
      recentSessions = List.from(stats['recent_sessions']);
    }

    recentSessions.add({
      'timestamp': DateTime.now().toIso8601String(),
      'edited_files': editedFiles,
    });

    if (recentSessions.length > _maxHistorySize) {
      recentSessions =
          recentSessions.sublist(recentSessions.length - _maxHistorySize);
    }

    stats['recent_sessions'] = recentSessions;

    try {
      if (!statsFile.parent.existsSync()) {
        statsFile.parent.createSync(recursive: true);
      }
      await statsFile.writeAsString(jsonEncode(stats));
    } catch (e) {
      _logger.warning('Failed to write stats file: $e');
    }
  }

  Future<int> getRecentEditCount(String userId, String filePath) async {
    final statsFile = _getStatsFile(userId);
    if (!statsFile.existsSync()) {
      return 0;
    }

    try {
      final content = await statsFile.readAsString();
      final stats = jsonDecode(content);

      if (!stats.containsKey('recent_sessions')) {
        return 0;
      }

      final recentSessions = stats['recent_sessions'] as List;
      var count = 0;
      final normalizedPath = p.normalize(filePath);

      for (final session in recentSessions) {
        final editedFiles = (session['edited_files'] as List).cast<String>();
        if (editedFiles.any((f) => p.normalize(f) == normalizedPath)) {
          count++;
        }
      }
      _logger.info(
          'File $filePath was edited $count times in the last $_maxHistorySize sessions.');
      return count;
    } catch (e) {
      _logger.warning('Failed to read stats file: $e');
      return 0;
    }
  }

  @visibleForTesting
  File Function(String userId)? getStatsFileOverride;

  File _getStatsFile(String userId) {
    if (getStatsFileOverride != null) {
      return getStatsFileOverride!(userId);
    }
    final systemPath = FileSystemService.instance.getSystemPath(userId);
    return File(p.join(systemPath, _statsFileName));
  }
}
