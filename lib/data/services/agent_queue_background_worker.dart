import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_queue_drain_scheduler.dart';
import 'package:memex/data/services/file_logger_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

class AgentQueueBackgroundWorker {
  static const Duration _maxRunDuration = Duration(seconds: 25);
  static const Duration _defaultRetryDelay = Duration(minutes: 15);
  static const int _databaseMaxAttempts = 3;

  static bool isAgentQueueDrainTask(String taskName) {
    return taskName == WorkmanagerAgentQueueDrainScheduler.taskName ||
        taskName == WorkmanagerAgentQueueDrainScheduler.uniqueName;
  }

  static Future<bool> run({
    Future<void> Function(String userId)? initializeTaskQueue,
    LocalTaskExecutor? executor,
    AgentQueueDrainScheduler? scheduler,
    AgentBackgroundPlatform? backgroundPlatform,
    Duration maxRunDuration = _maxRunDuration,
    Duration databaseRetryDelay = const Duration(milliseconds: 300),
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    await setupLogger();
    final logger = getLogger('AgentQueueBackgroundWorker');

    try {
      await UserStorage.initL10n();
      final userId = await UserStorage.getUserId();
      final surfacePlatform =
          backgroundPlatform ?? MethodChannelAgentBackgroundPlatform();
      if (userId == null || userId.isEmpty) {
        logger.info('Skipping agent queue drain: no active user.');
        await _stopBackgroundSurface(logger, surfacePlatform);
        return true;
      }

      final taskExecutor = executor ?? LocalTaskExecutor.instance;
      final queueScheduler = scheduler ?? WorkmanagerAgentQueueDrainScheduler();
      final result = await _withDatabaseLockRetry(
        logger,
        maxAttempts: _databaseMaxAttempts,
        retryDelay: databaseRetryDelay,
        operation: () async {
          if (initializeTaskQueue != null) {
            await initializeTaskQueue(userId);
          } else {
            await MemexRouter.ensureTaskQueueInitializedForBackgroundTask(
              userId,
              executor: taskExecutor,
            );
          }
          return taskExecutor.drainAvailableTasks(
            userId: userId,
            maxDuration: maxRunDuration,
            stopWhenDone: true,
          );
        },
      );

      if (result.snapshot.hasActiveTasks) {
        await queueScheduler.schedule(
          initialDelay: result.nextRunnableDelay ?? _defaultRetryDelay,
          expedited: false,
        );
      }
      await _syncBackgroundSurfaceAfterDrain(
        logger,
        surfacePlatform,
        result.snapshot,
      );

      logger.info(
        'Agent queue drain finished. '
        'active=${result.snapshot.total}, timedOut=${result.timedOut}',
      );
      return true;
    } catch (e, stackTrace) {
      logger.severe('Agent queue drain failed', e, stackTrace);
      return false;
    } finally {
      await FileLoggerService.instance.dispose();
    }
  }

  static Duration clampNextDelay(int? scheduledAtSeconds) {
    if (scheduledAtSeconds == null) return _defaultRetryDelay;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seconds = max(30, scheduledAtSeconds - now);
    return Duration(seconds: seconds);
  }

  static Future<void> _syncBackgroundSurfaceAfterDrain(
    Logger logger,
    AgentBackgroundPlatform platform,
    TaskActivitySnapshot snapshot,
  ) async {
    if (!platform.isSupported) return;

    if (!snapshot.hasActiveTasks) {
      await _stopBackgroundSurface(logger, platform);
      return;
    }

    try {
      await platform.updateStatus(
        AgentBackgroundStatus.fromActivity(taskSnapshot: snapshot),
        isInBackground: true,
      );
    } catch (e, stackTrace) {
      logger.warning(
        'Failed to refresh Android agent background surface after drain',
        e,
        stackTrace,
      );
    }
  }

  static Future<void> _stopBackgroundSurface(
    Logger logger,
    AgentBackgroundPlatform platform,
  ) async {
    if (!platform.isSupported) return;

    try {
      await platform.stopStatus();
    } catch (e, stackTrace) {
      logger.warning(
        'Failed to stop Android agent background surface after drain',
        e,
        stackTrace,
      );
    }
  }

  static Future<T> _withDatabaseLockRetry<T>(
    Logger logger, {
    required int maxAttempts,
    required Duration retryDelay,
    required Future<T> Function() operation,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await operation();
      } catch (e, stackTrace) {
        if (!_isDatabaseLocked(e) || attempt == maxAttempts) {
          Error.throwWithStackTrace(e, stackTrace);
        }
        logger.warning(
          'Agent queue drain hit a locked database '
          '(attempt $attempt/$maxAttempts); retrying.',
        );
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
    throw StateError('unreachable database retry path');
  }

  static bool isDatabaseLockedForTesting(Object error) =>
      _isDatabaseLocked(error);

  static bool _isDatabaseLocked(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('sqliteexception(5)') ||
        message.contains('code 5');
  }
}
