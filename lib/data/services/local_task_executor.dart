import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/task_exceptions.dart';
import 'package:memex/utils/logger.dart';

/// Context for task execution
class TaskContext {
  final String taskId;
  final String taskType;
  final String? bizId;

  TaskContext({
    required this.taskId,
    required this.taskType,
    this.bizId,
  });
}

/// Lightweight snapshot of active background task pressure.
class TaskActivitySnapshot {
  final int pending;
  final int processing;
  final int retrying;
  final Set<String> activeTaskIds;

  const TaskActivitySnapshot({
    required this.pending,
    required this.processing,
    required this.retrying,
    this.activeTaskIds = const <String>{},
  });

  const TaskActivitySnapshot.empty()
      : pending = 0,
        processing = 0,
        retrying = 0,
        activeTaskIds = const <String>{};

  int get total => pending + processing + retrying;

  bool get hasActiveTasks => total > 0;

  @override
  bool operator ==(Object other) {
    return other is TaskActivitySnapshot &&
        other.pending == pending &&
        other.processing == processing &&
        other.retrying == retrying &&
        setEquals(other.activeTaskIds, activeTaskIds);
  }

  @override
  int get hashCode => Object.hash(
        pending,
        processing,
        retrying,
        Object.hashAllUnordered(activeTaskIds),
      );
}

class TaskQueueDrainResult {
  const TaskQueueDrainResult({
    required this.snapshot,
    required this.timedOut,
    this.nextRunnableDelay,
  });

  final TaskActivitySnapshot snapshot;
  final bool timedOut;
  final Duration? nextRunnableDelay;
}

/// Handler function type
typedef TaskHandler = Future<void> Function(
    String userId, Map<String, dynamic> payload, TaskContext context);

typedef TaskConcurrencyKeyBuilder = String Function(
  String userId,
  Map<String, dynamic> payload,
  TaskContext context,
);

/// Per-task-type concurrency policy. The executor prefixes the returned key
/// with the task type, so [byUser] means "one task of this type per user".
class TaskConcurrencyPolicy {
  TaskConcurrencyPolicy._(
    this._keyBuilder, {
    required this.guardsProcessingTasksOfSameType,
  });

  final TaskConcurrencyKeyBuilder _keyBuilder;
  final bool guardsProcessingTasksOfSameType;

  factory TaskConcurrencyPolicy.byUser() {
    return TaskConcurrencyPolicy._(
      (userId, payload, context) => userId,
      guardsProcessingTasksOfSameType: true,
    );
  }

  String keyFor(
    String userId,
    Map<String, dynamic> payload,
    TaskContext context,
  ) {
    return _keyBuilder(userId, payload, context);
  }
}

/// Failure handler function type - called when all retries are exhausted
typedef TaskFailureHandler = Future<void> Function(
    String userId,
    Map<String, dynamic> payload,
    TaskContext context,
    Object error,
    StackTrace? stackTrace);

class LocalTaskExecutor {
  static LocalTaskExecutor? _instance;
  static LocalTaskExecutor get instance {
    _instance ??= LocalTaskExecutor._();
    return _instance!;
  }

  LocalTaskExecutor._() : _testDb = null;

  @visibleForTesting
  LocalTaskExecutor.forTesting({AppDatabase? db}) : _testDb = db;

  final Logger _logger = getLogger('LocalTaskExecutor');
  final AppDatabase? _testDb;
  // Dynamic getter to ensure we always use the current active DB instance (handling user switches)
  AppDatabase get _db => _testDb ?? AppDatabase.instance;
  String? _currentUserId; // Track current user ID for worker context
  String? get currentUserId => _currentUserId;

  // Handlers registry
  final Map<String, TaskHandler> _handlers = {};
  final Map<String, TaskConcurrencyPolicy> _concurrencyPolicies = {};
  final Set<String> _activeConcurrencyKeys = <String>{};
  final Map<String, Timer> _taskHeartbeatTimers = {};

  // Failure handlers registry
  final Map<String, TaskFailureHandler> _failureHandlers = {};

  // Worker state
  bool _isRunning = false;
  Timer? _pollTimer;
  bool _isProcessing = false;
  bool _autoPollEnabled = true;

  // Polling interval
  static const Duration _pollInterval = Duration(seconds: 1);
  static const String _crashGuardBucket = 'local_task_executor_crash_guard';
  static const String _activeTaskMarkerKeyPrefix = 'active_task_marker:';
  static const String _gracefulExitMarkerKey = 'graceful_exit_marker';
  static const int crashLoopFailureThreshold = 2;
  static const Duration crashLikeExitWindow = Duration(minutes: 10);
  static const Duration _taskHeartbeatInterval = Duration(seconds: 10);
  static const Duration _backgroundStaleTaskAge = Duration(seconds: 30);

  /// Stream that emits true if there are any active (pending, processing, retrying) tasks in the DB.
  /// Useful for global UI loading indicators.
  Stream<TaskActivitySnapshot> get taskActivitySnapshotStream {
    final query = _db.select(_db.tasks)
      ..where((t) => t.status.isIn(['pending', 'processing', 'retrying']));
    return query.watch().map(_snapshotFromTasks).distinct();
  }

  /// Stream that emits true if there are any active (pending, processing, retrying) tasks in the DB.
  /// Useful for global UI loading indicators.
  Stream<bool> get hasActiveTasksStream {
    return taskActivitySnapshotStream
        .map((snapshot) => snapshot.hasActiveTasks)
        .distinct();
  }

  Future<TaskActivitySnapshot> getTaskActivitySnapshot() async {
    final query = _db.select(_db.tasks)
      ..where((t) => t.status.isIn(['pending', 'processing', 'retrying']));
    return _snapshotFromTasks(await query.get());
  }

  Future<TaskQueueDrainResult> drainAvailableTasks({
    required String userId,
    Duration maxDuration = const Duration(seconds: 25),
    Duration pollInterval = const Duration(milliseconds: 200),
    bool stopWhenDone = false,
    Duration minimumStaleTaskAge = _backgroundStaleTaskAge,
  }) async {
    final wasRunning = _isRunning;
    if (!wasRunning) {
      await start(
        userId: userId,
        recoverStaleTasks: true,
        autoPoll: false,
        minimumStaleTaskAge: minimumStaleTaskAge,
      );
    } else {
      _currentUserId ??= userId;
    }

    final deadline = DateTime.now().add(maxDuration);
    var timedOut = false;
    try {
      while (true) {
        await _workerLoop(
          scheduleNextPoll: false,
          rethrowErrors: true,
          awaitClaimedTasks: true,
        );
        final hasProcessing = await _hasProcessingTasks();
        final hasRunnable = await _hasRunnableTasks();
        if (!hasProcessing && !hasRunnable) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          timedOut = true;
          break;
        }
        _scheduleNextPoll(immediate: true);
        await Future<void>.delayed(pollInterval);
      }

      return TaskQueueDrainResult(
        snapshot: await getTaskActivitySnapshot(),
        timedOut: timedOut,
        nextRunnableDelay: await _nextRunnableDelay(),
      );
    } finally {
      if (stopWhenDone || !wasRunning) {
        stop();
      }
    }
  }

  TaskActivitySnapshot _snapshotFromTasks(List<Task> tasks) {
    var pending = 0;
    var processing = 0;
    var retrying = 0;
    for (final task in tasks) {
      switch (task.status) {
        case 'pending':
          pending++;
          break;
        case 'processing':
          processing++;
          break;
        case 'retrying':
          retrying++;
          break;
      }
    }
    return TaskActivitySnapshot(
      pending: pending,
      processing: processing,
      retrying: retrying,
      activeTaskIds: tasks.map((task) => task.id).toSet(),
    );
  }

  void registerHandler(
    String taskType,
    TaskHandler handler, {
    TaskConcurrencyPolicy? concurrencyPolicy,
  }) {
    _handlers[taskType] = handler;
    if (concurrencyPolicy == null) {
      _concurrencyPolicies.remove(taskType);
    } else {
      _concurrencyPolicies[taskType] = concurrencyPolicy;
    }
  }

  /// Register a failure handler for a task type
  /// This handler will be called when all retries are exhausted and the task is permanently failed
  void registerFailureHandler(String taskType, TaskFailureHandler handler) {
    _failureHandlers[taskType] = handler;
  }

  /// Start the worker loop
  Future<void> start({
    String? userId,
    bool recoverStaleTasks = true,
    bool autoPoll = true,
    Duration? minimumStaleTaskAge,
  }) async {
    if (_isRunning) return;
    _currentUserId = userId; // Store for use in worker loop
    _autoPollEnabled = autoPoll;

    if (recoverStaleTasks) {
      // Detect whether the previous process exited while a task was running.
      // This must happen before resetting stale tasks, otherwise we lose the only
      // durable signal that a crash-like exit happened during task execution.
      await _handlePreviousExecutionMarkers(
        minimumStaleTaskAge: minimumStaleTaskAge,
      );

      // Reset any stale 'processing' tasks that might have been left over from a crash
      await _resetStaleTasks(minimumStaleTaskAge: minimumStaleTaskAge);
    }

    _isRunning = true;
    _logger.info('LocalTaskExecutor started for user $_currentUserId');
    if (_autoPollEnabled) {
      _scheduleNextPoll();
    }
  }

  /// Reset tasks that are stuck in 'processing' state to 'pending'
  Future<void> _resetStaleTasks({Duration? minimumStaleTaskAge}) async {
    try {
      final now = DateTime.now();
      final update = _db.update(_db.tasks)
        ..where((t) => t.status.equals('processing'));

      if (minimumStaleTaskAge != null) {
        final cutoff =
            now.subtract(minimumStaleTaskAge).millisecondsSinceEpoch ~/ 1000;
        final freshMarkerTaskIds = (await _loadTaskExecutionMarkers())
            .where((marker) => !marker.isStale(now, minimumStaleTaskAge))
            .map((marker) => marker.taskId)
            .toList();

        update.where(
          (t) =>
              t.updatedAt.isNull() | t.updatedAt.isSmallerOrEqualValue(cutoff),
        );
        if (freshMarkerTaskIds.isNotEmpty) {
          update.where((t) => t.id.isNotIn(freshMarkerTaskIds));
        }
      }

      final count = await update.write(TasksCompanion(
        status: const Value('pending'),
        updatedAt: Value(now.millisecondsSinceEpoch ~/ 1000),
      ));

      if (count > 0) {
        _logger.info('Reset $count stale processing tasks to pending');
      }
    } catch (e) {
      _logger.severe('Failed to reset stale tasks: $e');
    }
  }

  /// Stop the worker loop
  void stop() {
    _isRunning = false;
    _autoPollEnabled = true;
    _pollTimer?.cancel();
    for (final timer in _taskHeartbeatTimers.values) {
      timer.cancel();
    }
    _taskHeartbeatTimers.clear();
    _logger.info('LocalTaskExecutor stopped');
  }

  Future<void> recordGracefulShutdown({String reason = 'unknown'}) async {
    if (!AppDatabase.isInitialized) return;

    final marker = _GracefulExitMarker(
      markedAt: DateTime.now(),
      reason: reason,
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.into(_db.kvStore).insertOnConflictUpdate(
          KvStoreCompanion.insert(
            key: _gracefulExitMarkerKey,
            value: Value(jsonEncode(marker.toJson())),
            bucket: const Value(_crashGuardBucket),
            updatedAt: Value(now),
          ),
        );
  }

  Future<void> clearGracefulShutdownMarker() async {
    if (!AppDatabase.isInitialized) return;

    await (_db.delete(_db.kvStore)
          ..where((kv) => kv.key.equals(_gracefulExitMarkerKey)))
        .go();
  }

  // Max concurrent tasks
  static const int _maxConcurrency = 5;
  static const int _candidatePageSize = 50;
  static const int _maxCandidateScan = 500;

  /// Enqueue a new task
  Future<String> enqueueTask({
    required String userId,
    required String taskType,
    required Map<String, dynamic> payload,
    int priority = 0,
    int? scheduledAt,
    int maxRetries = 5,
    String? bizId,
    List<String>? dependencies,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // We use a manual UUID or let Drift handle it?
    // Our schema defined ID as Text. Drift doesn't auto-generate Text IDs usually.
    // So we generate one.
    final taskId =
        DateTime.now().microsecondsSinceEpoch.toString(); // Simple ID for now

    await _db.into(_db.tasks).insert(TasksCompanion.insert(
          id: taskId,
          type: taskType,
          payload: Value(jsonEncode(payload)),
          status: 'pending',
          priority: Value(priority),
          createdAt: Value(now),
          scheduledAt: Value(scheduledAt),
          maxRetries: Value(maxRetries),
          bizId: Value(bizId),
          dependencies: Value(dependencies != null && dependencies.isNotEmpty
              ? jsonEncode(dependencies)
              : null),
        ));

    _logger.info('Enqueued task $taskId ($taskType)');

    // Trigger immediate poll if running
    if (_isRunning) {
      _scheduleNextPoll(immediate: true);
    }

    return taskId;
  }

  void _scheduleNextPoll({bool immediate = false}) {
    _pollTimer?.cancel();
    if (!_isRunning || !_autoPollEnabled) return;

    if (immediate) {
      _pollTimer = Timer(Duration.zero, _workerLoop);
    } else {
      _pollTimer = Timer(_pollInterval, _workerLoop);
    }
  }

  Future<void> _workerLoop({
    bool scheduleNextPoll = true,
    bool rethrowErrors = false,
    bool awaitClaimedTasks = false,
  }) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // 1. Check current active tasks count
      final activeCountQuery = _db.select(_db.tasks)
        ..where((t) => t.status.isIn(['processing']));
      final activeTasks = await activeCountQuery.get();

      if (activeTasks.length >= _maxConcurrency) {
        _isProcessing = false;
        if (scheduleNextPoll) {
          _scheduleNextPoll(); // Wait for next slot
        }
        return;
      }

      final slotsAvailable = _maxConcurrency - activeTasks.length;

      // 2. Fetch runnable tasks. Dependency-blocked tasks at the front of the
      // queue should not starve later tasks that can safely run now.
      final tasksToRun = await _findRunnableTasks(
        slotsAvailable: slotsAvailable,
        now: now,
      );

      if (tasksToRun.isEmpty) {
        // No runnable tasks found in top candidates
        _isProcessing = false;
        if (scheduleNextPoll) {
          _scheduleNextPoll();
        }
        return;
      }

      // 3. Claim tasks before starting handlers so immediate polling cannot
      // pick the same pending row again while execution starts asynchronously.
      final claimedTasks = <Task>[];
      final claimedConcurrencyKeys = <String, String?>{};
      for (final task in tasksToRun) {
        final concurrencyKey = _concurrencyKeyForTask(task);
        final acquiredConcurrencyKey = concurrencyKey == null
            ? false
            : _activeConcurrencyKeys.add(concurrencyKey);
        if (concurrencyKey != null && !acquiredConcurrencyKey) {
          _logger.info(
            'Deferring task ${task.id} (${task.type}) because $concurrencyKey is already running',
          );
          continue;
        }

        try {
          if (await _claimTaskForExecution(
            task,
            now,
            concurrencyKey: concurrencyKey,
          )) {
            claimedTasks.add(task);
            claimedConcurrencyKeys[task.id] = concurrencyKey;
          } else if (acquiredConcurrencyKey) {
            _activeConcurrencyKeys.remove(concurrencyKey);
          }
        } catch (_) {
          if (acquiredConcurrencyKey) {
            _activeConcurrencyKeys.remove(concurrencyKey);
          }
          rethrow;
        }
      }

      final executionFutures = <Future<void>>[];
      for (final task in claimedTasks) {
        final executionFuture = _executeTask(
          task,
          concurrencyKey: claimedConcurrencyKeys[task.id],
        );
        if (awaitClaimedTasks) {
          executionFutures.add(executionFuture);
        } else {
          unawaited(executionFuture);
        }
      }

      if (executionFutures.isNotEmpty) {
        await Future.wait(executionFutures);
      }

      // Loop immediately to check for more tasks or completion
      _isProcessing = false;

      // If we filled all slots, wait. If we didn't, maybe check again soon.
      // Easiest is to just schedule next poll.
      if (scheduleNextPoll) {
        _scheduleNextPoll(immediate: true);
      }
    } catch (e, stackTrace) {
      _isProcessing = false;
      if (rethrowErrors) {
        Error.throwWithStackTrace(e, stackTrace);
      }
      if (_isDatabaseLockedError(e)) {
        _logger.warning(
          'Database locked in worker loop; retrying on next poll.',
        );
        if (scheduleNextPoll) {
          _scheduleNextPoll();
        }
        return;
      }
      _logger.severe('Error in worker loop, $e', e, stackTrace);
      if (scheduleNextPoll) {
        _scheduleNextPoll();
      }
    }
  }

  bool _isDatabaseLockedError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('sqliteexception(5)') ||
        message.contains('code 5');
  }

  Future<List<Task>> _findRunnableTasks({
    required int slotsAvailable,
    required int now,
  }) async {
    final tasksToRun = <Task>[];
    final reservedConcurrencyKeys = <String>{};
    var offset = 0;
    var scanned = 0;

    while (tasksToRun.length < slotsAvailable && scanned < _maxCandidateScan) {
      final remainingScan = _maxCandidateScan - scanned;
      final pageSize = remainingScan < _candidatePageSize
          ? remainingScan
          : _candidatePageSize;

      final query = _db.select(_db.tasks)
        ..where((t) => t.status.isIn(['pending', 'retrying']))
        ..where((t) =>
            t.scheduledAt.isNull() | t.scheduledAt.isSmallerOrEqualValue(now))
        ..orderBy([
          (t) => OrderingTerm(expression: t.priority, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.rowId, mode: OrderingMode.asc),
        ])
        ..limit(pageSize, offset: offset);

      final candidates = await query.get();
      if (candidates.isEmpty) break;

      scanned += candidates.length;
      offset += candidates.length;

      for (final task in candidates) {
        if (tasksToRun.length >= slotsAvailable) break;
        if (await _dependenciesMet(task)) {
          final concurrencyKey = _concurrencyKeyForTask(task);
          if (concurrencyKey != null) {
            if (_activeConcurrencyKeys.contains(concurrencyKey) ||
                reservedConcurrencyKeys.contains(concurrencyKey) ||
                await _hasProcessingConcurrencyConflict(
                  task,
                  concurrencyKey,
                )) {
              continue;
            }
            reservedConcurrencyKeys.add(concurrencyKey);
          }
          tasksToRun.add(task);
        }
      }
    }

    if (tasksToRun.isEmpty && scanned >= _maxCandidateScan) {
      _logger.warning(
          'No runnable tasks found after scanning $_maxCandidateScan candidates');
    }

    return tasksToRun;
  }

  Future<bool> _hasProcessingTasks() async {
    final query = _db.selectOnly(_db.tasks)
      ..addColumns([_db.tasks.id.count()])
      ..where(_db.tasks.status.equals('processing'));
    final row = await query.getSingle();
    return (row.read(_db.tasks.id.count()) ?? 0) > 0;
  }

  Future<bool> _hasRunnableTasks() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (await _findRunnableTasks(slotsAvailable: 1, now: now)).isNotEmpty;
  }

  Future<Duration?> _nextRunnableDelay() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final query = _db.select(_db.tasks)
      ..where((t) => t.status.isIn(['pending', 'retrying']))
      ..where((t) => t.scheduledAt.isBiggerThanValue(now))
      ..orderBy([
        (t) => OrderingTerm(expression: t.scheduledAt, mode: OrderingMode.asc),
      ])
      ..limit(1);
    final task = await query.getSingleOrNull();
    if (task?.scheduledAt == null) return null;
    final seconds = task!.scheduledAt! - now;
    return Duration(seconds: seconds < 30 ? 30 : seconds);
  }

  String? _concurrencyKeyForTask(Task task) {
    final policy = _concurrencyPolicies[task.type];
    if (policy == null) return null;
    final currentUserId = _currentUserId;
    if (currentUserId == null) return null;

    try {
      final payloadMap = _decodePayload(task);
      final context = TaskContext(
        taskId: task.id,
        taskType: task.type,
        bizId: task.bizId,
      );
      return '${task.type}:${policy.keyFor(currentUserId, payloadMap, context)}';
    } catch (e, st) {
      _logger.warning(
        'Failed to build concurrency key for task ${task.id}',
        e,
        st,
      );
      return null;
    }
  }

  Future<bool> _hasProcessingConcurrencyConflict(
    Task task,
    String concurrencyKey,
  ) async {
    if (!_usesSameTypeDatabaseConcurrencyGuard(task, concurrencyKey)) {
      return false;
    }

    final query = _db.selectOnly(_db.tasks)
      ..addColumns([_db.tasks.id.count()])
      ..where(_db.tasks.status.equals('processing'))
      ..where(_db.tasks.type.equals(task.type));
    final row = await query.getSingle();
    return (row.read(_db.tasks.id.count()) ?? 0) > 0;
  }

  bool _usesSameTypeDatabaseConcurrencyGuard(
    Task task,
    String? concurrencyKey,
  ) {
    return concurrencyKey != null &&
        (_concurrencyPolicies[task.type]?.guardsProcessingTasksOfSameType ??
            false);
  }

  Map<String, dynamic> _decodePayload(Task task) {
    return task.payload != null
        ? jsonDecode(task.payload!) as Map<String, dynamic>
        : <String, dynamic>{};
  }

  Future<bool> _dependenciesMet(Task task) async {
    if (task.dependencies == null) return true;

    try {
      final deps = (jsonDecode(task.dependencies!) as List).cast<String>();
      if (deps.isEmpty) return true;

      // Check if any dependency is NOT completed or failed.
      final pendingDepsQuery = _db.selectOnly(_db.tasks)
        ..addColumns([_db.tasks.id.count()])
        ..where(_db.tasks.id.isIn(deps))
        ..where(_db.tasks.status.isNotIn(['completed', 'failed']));

      final pendingCount = await pendingDepsQuery.getSingle();
      return (pendingCount.read(_db.tasks.id.count()) ?? 0) == 0;
    } catch (e) {
      _logger.warning('Failed to parse dependencies for task ${task.id}: $e');
      await _failTask(task, 'Invalid task dependencies: $e');
      return false;
    }
  }

  Future<void> _executeTask(Task task, {String? concurrencyKey}) async {
    try {
      final handler = _handlers[task.type];
      if (handler == null) {
        throw Exception('No handler registered for task type: ${task.type}');
      }

      final payloadMap = _decodePayload(task);

      final currentUserId = _currentUserId;
      if (currentUserId == null) {
        throw StateError(
          'Task execution failed: no active user ID in LocalTaskExecutor',
        );
      }

      await handler(
        currentUserId,
        payloadMap,
        TaskContext(
          taskId: task.id,
          taskType: task.type,
          bizId: task.bizId,
        ),
      );

      // Success
      await (_db.update(_db.tasks)..where((t) => t.id.equals(task.id))).write(
        TasksCompanion(
          status: const Value('completed'),
          completedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        ),
      );

      _logger.info('Task ${task.id} completed');
    } catch (e, stack) {
      _logger.severe('Task ${task.id} failed', e, stack);

      // Retry Logic
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final nextRetry = task.retryCount + 1;

      if (e is! NonRetryableTaskException && nextRetry <= task.maxRetries) {
        // Exponential backoff
        const backoff = 30; //* (1 << (task.retryCount));
        final nextRun = now + backoff;

        await (_db.update(_db.tasks)..where((t) => t.id.equals(task.id))).write(
          TasksCompanion(
            status: const Value('retrying'),
            retryCount: Value(nextRetry),
            updatedAt: Value(now),
            // For simple polling, we don't strictly update scheduledAt for retries currently in query logic
            // but we should if we want valid backoff.
            // Existing query handles scheduledAt logic, so updating it works.
            scheduledAt: Value(nextRun),
            error: Value(e.toString()),
          ),
        );
        _logger.info('Task ${task.id} scheduled for retry at $nextRun');
      } else {
        // Permanently failed
        final failureHandler = _failureHandlers[task.type];
        if (failureHandler != null) {
          try {
            final payloadMap = task.payload != null
                ? jsonDecode(task.payload!) as Map<String, dynamic>
                : <String, dynamic>{};
            final currentUserId = _currentUserId;
            if (currentUserId != null) {
              await failureHandler(
                currentUserId,
                payloadMap,
                TaskContext(
                  taskId: task.id,
                  taskType: task.type,
                  bizId: task.bizId,
                ),
                e,
                stack,
              );
            }
          } catch (fhError, fhStack) {
            _logger.severe('Failure handler error', fhError, fhStack);
          }
        }

        await (_db.update(_db.tasks)..where((t) => t.id.equals(task.id))).write(
          TasksCompanion(
            status: const Value('failed'),
            completedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
            updatedAt: Value(now),
            error: Value(e.toString()),
          ),
        );
        _logger.severe('Task ${task.id} permanently failed');
      }
    } finally {
      _stopTaskHeartbeat(task.id);
      await _clearTaskExecutionMarker(task.id);
      if (concurrencyKey != null) {
        _activeConcurrencyKeys.remove(concurrencyKey);
      }

      // Trigger poll to pick up next tasks immediately upon completion of one
      if (_isRunning) {
        _scheduleNextPoll(immediate: true);
      }
    }
  }

  Future<bool> _claimTaskForExecution(
    Task task,
    int now, {
    String? concurrencyKey,
  }) async {
    final guardSameType =
        _usesSameTypeDatabaseConcurrencyGuard(task, concurrencyKey);
    final sql = StringBuffer(
      'UPDATE tasks '
      'SET status = ?, updated_at = ? '
      'WHERE id = ? '
      'AND status IN (?, ?) '
      'AND (SELECT COUNT(*) FROM tasks WHERE status = ?) < ?',
    );
    final variables = <Variable>[
      const Variable<String>('processing'),
      Variable<int>(now),
      Variable<String>(task.id),
      const Variable<String>('pending'),
      const Variable<String>('retrying'),
      const Variable<String>('processing'),
      const Variable<int>(_maxConcurrency),
    ];

    if (guardSameType) {
      sql.write(
        ' AND NOT EXISTS ('
        'SELECT 1 FROM tasks '
        'WHERE status = ? AND type = ?'
        ')',
      );
      variables.addAll([
        const Variable<String>('processing'),
        Variable<String>(task.type),
      ]);
    }

    final updated = await _db.customUpdate(
      sql.toString(),
      variables: variables,
      updates: {_db.tasks},
    );
    if (updated == 0) return false;

    await _markTaskExecutionStarted(task, startHeartbeat: true);
    return true;
  }

  Future<void> _handlePreviousExecutionMarkers({
    Duration? minimumStaleTaskAge,
  }) async {
    try {
      final markers = await _loadTaskExecutionMarkers();
      if (markers.isEmpty) return;
      final gracefulExitMarker = await _loadGracefulExitMarker();

      for (final marker in markers) {
        await _handlePreviousExecutionMarker(
          marker,
          gracefulExitMarker,
          minimumStaleTaskAge: minimumStaleTaskAge,
        );
      }
      await _deleteGracefulExitMarker();
    } catch (e, stack) {
      _logger.severe(
        'Failed to handle previous task execution markers',
        e,
        stack,
      );
    }
  }

  Future<void> _handlePreviousExecutionMarker(
      _TaskExecutionMarker marker, _GracefulExitMarker? gracefulExitMarker,
      {Duration? minimumStaleTaskAge}) async {
    final task = await (_db.select(
      _db.tasks,
    )..where((t) => t.id.equals(marker.taskId)))
        .getSingleOrNull();
    if (task == null || task.status != 'processing') {
      await _deleteTaskExecutionMarker(marker.taskId);
      return;
    }

    if (!marker.matchesTask(task)) {
      _logger.warning(
        'Ignoring stale crash guard marker for task ${marker.taskId}: task metadata changed',
      );
      await _deleteTaskExecutionMarker(marker.taskId);
      return;
    }

    if (gracefulExitMarker != null &&
        !gracefulExitMarker.markedAt.isBefore(marker.startedAt)) {
      _logger.info(
        'Ignoring crash guard marker for task ${marker.taskId}: previous app exit was graceful (${gracefulExitMarker.reason})',
      );
      await _deleteTaskExecutionMarker(marker.taskId);
      return;
    }

    final now = DateTime.now();
    if (minimumStaleTaskAge != null &&
        !marker.isStale(now, minimumStaleTaskAge)) {
      return;
    }

    if (now.difference(marker.startedAt) > crashLikeExitWindow) {
      _logger.info(
        'Ignoring old crash guard marker for task ${marker.taskId}; previous process likely stopped outside crash window',
      );
      await _deleteTaskExecutionMarker(marker.taskId);
      return;
    }

    final updatedMarker = marker.copyWith(crashCount: marker.crashCount + 1);
    if (updatedMarker.crashCount >= crashLoopFailureThreshold) {
      await _failTask(
        task,
        'Task failed after ${updatedMarker.crashCount} crash-like exits while processing. '
        'Marked failed to stop startup crash loop.',
      );
      await _deleteTaskExecutionMarker(marker.taskId);
      _logger.severe(
        'Task ${task.id} failed by crash loop guard after ${updatedMarker.crashCount} crash-like exits',
      );
      return;
    }

    await _saveTaskExecutionMarker(updatedMarker);
    _logger.warning(
      'Detected crash-like exit while processing task ${task.id}; crash count is ${updatedMarker.crashCount}',
    );
  }

  Future<void> _markTaskExecutionStarted(
    Task task, {
    bool startHeartbeat = false,
  }) async {
    await clearGracefulShutdownMarker();
    final existing = await _loadTaskExecutionMarker(task.id);
    final marker = _TaskExecutionMarker.fromTask(
      task,
      crashCount: existing != null && existing.matchesTask(task)
          ? existing.crashCount
          : 0,
    );
    await _saveTaskExecutionMarker(marker);
    if (startHeartbeat) {
      _startTaskHeartbeat(task.id);
    }
  }

  void _startTaskHeartbeat(String taskId) {
    _taskHeartbeatTimers[taskId]?.cancel();
    _taskHeartbeatTimers[taskId] = Timer.periodic(
      _taskHeartbeatInterval,
      (_) => unawaited(_touchTaskExecutionMarker(taskId)),
    );
  }

  void _stopTaskHeartbeat(String taskId) {
    _taskHeartbeatTimers.remove(taskId)?.cancel();
  }

  Future<void> _touchTaskExecutionMarker(String taskId) async {
    final marker = await _loadTaskExecutionMarker(taskId);
    if (marker == null) return;
    await _saveTaskExecutionMarker(
      marker.copyWith(heartbeatAt: DateTime.now()),
    );
  }

  Future<_TaskExecutionMarker?> _loadTaskExecutionMarker(String taskId) async {
    final row = await (_db.select(
      _db.kvStore,
    )..where((kv) => kv.key.equals(_taskExecutionMarkerKey(taskId))))
        .getSingleOrNull();
    if (row?.value == null) return null;

    try {
      return _TaskExecutionMarker.fromJson(
        jsonDecode(row!.value!) as Map<String, dynamic>,
      );
    } catch (e) {
      _logger.warning('Failed to parse task execution marker: $e');
      await _deleteTaskExecutionMarker(taskId);
      return null;
    }
  }

  Future<List<_TaskExecutionMarker>> _loadTaskExecutionMarkers() async {
    final rows = await (_db.select(_db.kvStore)
          ..where((kv) => kv.key.like('$_activeTaskMarkerKeyPrefix%')))
        .get();
    final markers = <_TaskExecutionMarker>[];

    for (final row in rows) {
      if (row.value == null) {
        await _deleteTaskExecutionMarkerByKey(row.key);
        continue;
      }

      try {
        markers.add(
          _TaskExecutionMarker.fromJson(
            jsonDecode(row.value!) as Map<String, dynamic>,
          ),
        );
      } catch (e) {
        _logger.warning('Failed to parse task execution marker: $e');
        await _deleteTaskExecutionMarkerByKey(row.key);
      }
    }

    return markers;
  }

  Future<_GracefulExitMarker?> _loadGracefulExitMarker() async {
    final row = await (_db.select(_db.kvStore)
          ..where((kv) => kv.key.equals(_gracefulExitMarkerKey)))
        .getSingleOrNull();
    if (row?.value == null) return null;

    try {
      return _GracefulExitMarker.fromJson(
        jsonDecode(row!.value!) as Map<String, dynamic>,
      );
    } catch (e) {
      _logger.warning('Failed to parse graceful exit marker: $e');
      await _deleteGracefulExitMarker();
      return null;
    }
  }

  Future<void> _deleteGracefulExitMarker() async {
    await (_db.delete(_db.kvStore)
          ..where((kv) => kv.key.equals(_gracefulExitMarkerKey)))
        .go();
  }

  Future<void> _saveTaskExecutionMarker(_TaskExecutionMarker marker) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.into(_db.kvStore).insertOnConflictUpdate(
          KvStoreCompanion.insert(
            key: _taskExecutionMarkerKey(marker.taskId),
            value: Value(jsonEncode(marker.toJson())),
            bucket: const Value(_crashGuardBucket),
            updatedAt: Value(now),
          ),
        );
  }

  Future<void> _deleteTaskExecutionMarker(String taskId) {
    return _deleteTaskExecutionMarkerByKey(_taskExecutionMarkerKey(taskId));
  }

  Future<void> _deleteTaskExecutionMarkerByKey(String key) async {
    await (_db.delete(
      _db.kvStore,
    )..where((kv) => kv.key.equals(key)))
        .go();
  }

  Future<void> _clearTaskExecutionMarker(String taskId) async {
    final marker = await _loadTaskExecutionMarker(taskId);
    if (marker == null || marker.taskId != taskId) return;
    await _deleteTaskExecutionMarker(taskId);
  }

  String _taskExecutionMarkerKey(String taskId) {
    return '$_activeTaskMarkerKeyPrefix$taskId';
  }

  Future<void> _failTask(Task task, String error) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await (_db.update(_db.tasks)..where((t) => t.id.equals(task.id))).write(
      TasksCompanion(
        status: const Value('failed'),
        completedAt: Value(now),
        updatedAt: Value(now),
        error: Value(error),
      ),
    );
  }

  @visibleForTesting
  Future<void> markTaskExecutionStartedForTesting(Task task) =>
      _markTaskExecutionStarted(task);

  @visibleForTesting
  Future<KvStoreData?> getTaskExecutionMarkerForTesting([String? taskId]) {
    if (taskId != null) {
      return (_db.select(
        _db.kvStore,
      )..where((kv) => kv.key.equals(_taskExecutionMarkerKey(taskId))))
          .getSingleOrNull();
    }

    return (_db.select(
      _db.kvStore,
    )
          ..where((kv) => kv.key.like('$_activeTaskMarkerKeyPrefix%'))
          ..limit(1))
        .getSingleOrNull();
  }

  @visibleForTesting
  Future<List<KvStoreData>> getTaskExecutionMarkersForTesting() {
    return (_db.select(
      _db.kvStore,
    )..where((kv) => kv.key.like('$_activeTaskMarkerKeyPrefix%')))
        .get();
  }

  @visibleForTesting
  Future<KvStoreData?> getGracefulExitMarkerForTesting() {
    return (_db.select(_db.kvStore)
          ..where((kv) => kv.key.equals(_gracefulExitMarkerKey)))
        .getSingleOrNull();
  }

  /// Check if a task of [taskType] with [bizId] has failed.
  /// Returns the error string if failed, null otherwise.
  Future<String?> getTaskErrorByBizId(String taskType, String bizId) async {
    final query = _db.select(_db.tasks)
      ..where((t) => t.type.equals(taskType))
      ..where((t) => t.bizId.equals(bizId))
      ..where((t) => t.status.equals('failed'))
      ..limit(1);
    final task = await query.getSingleOrNull();
    return task?.error;
  }

  /// Update task result (called by handlers)
  Future<void> updateTaskResult(String taskId, String result) async {
    await (_db.update(_db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(
        result: Value(result),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
  }

  /// Create a completed task record with the given result directly.
  /// Useful for mocking task results that were not produced by an actual task execution.
  Future<void> saveTaskResult({
    required String userId,
    required String taskType,
    required String bizId,
    required Map<String, dynamic> result,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    final resultStr = jsonEncode(result);

    await _db.into(_db.tasks).insert(TasksCompanion.insert(
          id: taskId,
          type: taskType,
          payload: const Value("{}"),
          status: 'completed',
          priority: const Value(0),
          createdAt: Value(now),
          completedAt: Value(now),
          updatedAt: Value(now),
          maxRetries: const Value(1),
          bizId: Value(bizId),
          result: Value(resultStr),
        ));
  }

  /// Get task result by taskId (for resumption)
  Future<Map<String, dynamic>?> getTaskResult(String taskId) async {
    final query = _db.select(_db.tasks)..where((t) => t.id.equals(taskId));
    final task = await query.getSingleOrNull();

    if (task != null && task.result != null) {
      try {
        return jsonDecode(task.result!) as Map<String, dynamic>;
      } catch (e) {
        _logger.warning('Failed to parse task result for task ${task.id}: $e');
      }
    }
    return null;
  }

  /// Get task result by bizId
  Future<Map<String, dynamic>?> getTaskResultByBizId(
      String userId, String taskType, String bizId) async {
    final query = _db.select(_db.tasks)
      ..where((t) => t.type.equals(taskType))
      ..where((t) => t.bizId.equals(bizId))
      ..where((t) => t.status.equals('completed'))
      ..orderBy([
        (t) => OrderingTerm(expression: t.completedAt, mode: OrderingMode.desc)
      ])
      ..limit(1);

    final task = await query.getSingleOrNull();
    if (task != null && task.result != null) {
      try {
        return jsonDecode(task.result!) as Map<String, dynamic>;
      } catch (e) {
        _logger.warning('Failed to parse task result for task ${task.id}: $e');
      }
    }
    return null;
  }

  /// Get tasks with pagination
  Future<List<Task>> getTasks({int limit = 10, int offset = 0}) async {
    final query = _db.select(_db.tasks)
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);

    return await query.get();
  }

  /// Get the last task by type
  /// This is useful for restoring sequential dependency chains after app restart
  Future<String?> getLastTaskByType(String taskType) async {
    final query = _db.selectOnly(_db.tasks)
      ..addColumns([_db.tasks.id])
      ..where(_db.tasks.type.equals(taskType))
      ..orderBy([
        OrderingTerm(expression: _db.tasks.createdAt, mode: OrderingMode.desc),
        OrderingTerm(expression: _db.tasks.rowId, mode: OrderingMode.desc),
      ])
      ..limit(1);

    final result = await query.getSingleOrNull();
    return result?.read(_db.tasks.id);
  }
}

class _TaskExecutionMarker {
  _TaskExecutionMarker({
    required this.taskId,
    required this.taskType,
    required this.payloadHash,
    required this.startedAt,
    required this.heartbeatAt,
    required this.crashCount,
    this.bizId,
  });

  final String taskId;
  final String taskType;
  final String? bizId;
  final String payloadHash;
  final DateTime startedAt;
  final DateTime heartbeatAt;
  final int crashCount;

  factory _TaskExecutionMarker.fromTask(Task task, {required int crashCount}) {
    final now = DateTime.now();
    return _TaskExecutionMarker(
      taskId: task.id,
      taskType: task.type,
      bizId: task.bizId,
      payloadHash: _payloadHashFor(task.payload),
      startedAt: now,
      heartbeatAt: now,
      crashCount: crashCount,
    );
  }

  factory _TaskExecutionMarker.fromJson(Map<String, dynamic> json) {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(
      json['started_at_ms'] as int,
    );
    return _TaskExecutionMarker(
      taskId: json['task_id'] as String,
      taskType: json['task_type'] as String,
      bizId: json['biz_id'] as String?,
      payloadHash: json['payload_hash'] as String,
      startedAt: startedAt,
      heartbeatAt: DateTime.fromMillisecondsSinceEpoch(
        json['heartbeat_at_ms'] as int? ?? startedAt.millisecondsSinceEpoch,
      ),
      crashCount: json['crash_count'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'task_id': taskId,
      'task_type': taskType,
      'biz_id': bizId,
      'payload_hash': payloadHash,
      'started_at_ms': startedAt.millisecondsSinceEpoch,
      'heartbeat_at_ms': heartbeatAt.millisecondsSinceEpoch,
      'crash_count': crashCount,
    };
  }

  _TaskExecutionMarker copyWith({
    int? crashCount,
    DateTime? heartbeatAt,
  }) {
    return _TaskExecutionMarker(
      taskId: taskId,
      taskType: taskType,
      bizId: bizId,
      payloadHash: payloadHash,
      startedAt: startedAt,
      heartbeatAt: heartbeatAt ?? this.heartbeatAt,
      crashCount: crashCount ?? this.crashCount,
    );
  }

  bool isStale(DateTime now, Duration minimumStaleTaskAge) {
    return !now.difference(heartbeatAt).isNegative &&
        now.difference(heartbeatAt) >= minimumStaleTaskAge;
  }

  bool matchesTask(Task task) {
    return task.id == taskId &&
        task.type == taskType &&
        task.bizId == bizId &&
        _payloadHashFor(task.payload) == payloadHash;
  }

  static String _payloadHashFor(String? payload) {
    return sha256.convert(utf8.encode(payload ?? '')).toString();
  }
}

class _GracefulExitMarker {
  _GracefulExitMarker({
    required this.markedAt,
    required this.reason,
  });

  final DateTime markedAt;
  final String reason;

  factory _GracefulExitMarker.fromJson(Map<String, dynamic> json) {
    return _GracefulExitMarker(
      markedAt: DateTime.fromMillisecondsSinceEpoch(
        json['marked_at_ms'] as int,
      ),
      reason: json['reason'] as String? ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'marked_at_ms': markedAt.millisecondsSinceEpoch,
      'reason': reason,
    };
  }
}
