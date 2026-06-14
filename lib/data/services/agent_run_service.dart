import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/logger.dart';

enum AgentRunState {
  queued,
  running,
  pausedBySystem,
  completed,
  failed,
}

class AgentRunSnapshot {
  const AgentRunSnapshot({
    required this.id,
    required this.userId,
    required this.factId,
    required this.state,
    required this.stage,
    required this.completedUnits,
    required this.totalUnits,
    required this.remainingTasks,
    required this.updatedAt,
    this.message,
    this.currentTaskId,
    this.currentTaskType,
    this.lastError,
  });

  factory AgentRunSnapshot.fromDb(AgentRun row) {
    return AgentRunSnapshot(
      id: row.id,
      userId: row.userId,
      factId: row.factId,
      state: _stateFromDb(row.state),
      stage: row.stage,
      message: row.message,
      completedUnits: row.completedUnits,
      totalUnits: row.totalUnits,
      remainingTasks: row.remainingTasks,
      currentTaskId: row.currentTaskId,
      currentTaskType: row.currentTaskType,
      lastError: row.lastError,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt * 1000),
    );
  }

  final String id;
  final String userId;
  final String factId;
  final AgentRunState state;
  final String stage;
  final String? message;
  final int completedUnits;
  final int totalUnits;
  final int remainingTasks;
  final String? currentTaskId;
  final String? currentTaskType;
  final String? lastError;
  final DateTime updatedAt;

  bool get isVisible =>
      state == AgentRunState.queued ||
      state == AgentRunState.running ||
      state == AgentRunState.pausedBySystem ||
      state == AgentRunState.failed;
}

class AgentRunService {
  AgentRunService._() : _testDb = null;

  static AgentRunService? _instance;
  static AgentRunService get instance {
    _instance ??= AgentRunService._();
    return _instance!;
  }

  @visibleForTesting
  AgentRunService.forTesting({AppDatabase? db}) : _testDb = db;

  final AppDatabase? _testDb;
  final _logger = getLogger('AgentRunService');

  AppDatabase get _db => _testDb ?? AppDatabase.instance;

  bool get isAvailable => _testDb != null || AppDatabase.isInitialized;

  static const int defaultTotalUnits = 100;

  Stream<AgentRunSnapshot?> watchLatestVisibleRun({String? userId}) {
    final query = _db.select(_db.agentRuns)
      ..where((run) => run.state.isIn(_visibleDbStates));
    if (userId != null && userId.isNotEmpty) {
      query.where((run) => run.userId.equals(userId));
    }
    query
      ..orderBy([
        (run) => OrderingTerm(
              expression: run.updatedAt,
              mode: OrderingMode.desc,
            ),
      ])
      ..limit(1);

    return query.watchSingleOrNull().map((row) {
      return row == null ? null : AgentRunSnapshot.fromDb(row);
    }).distinct(_sameSnapshot);
  }

  Future<AgentRunSnapshot?> getLatestVisibleRun({String? userId}) async {
    final query = _db.select(_db.agentRuns)
      ..where((run) => run.state.isIn(_visibleDbStates));
    if (userId != null && userId.isNotEmpty) {
      query.where((run) => run.userId.equals(userId));
    }
    query
      ..orderBy([
        (run) => OrderingTerm(
              expression: run.updatedAt,
              mode: OrderingMode.desc,
            ),
      ])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : AgentRunSnapshot.fromDb(row);
  }

  Future<void> createForSubmittedInput({
    required String userId,
    required String factId,
  }) async {
    final now = _nowSeconds();
    await _db.into(_db.agentRuns).insertOnConflictUpdate(
          AgentRunsCompanion.insert(
            id: factId,
            userId: userId,
            factId: factId,
            state: _dbState(AgentRunState.queued),
            stage: 'Queued',
            message: const Value('Waiting for background processing to start.'),
            completedUnits: const Value(0),
            totalUnits: const Value(defaultTotalUnits),
            remainingTasks: const Value(0),
            createdAt: now,
            updatedAt: now,
          ),
        );
    _logger.info('Created agent run for $factId');
  }

  Future<void> refreshRunFromTasks(String runId) async {
    final run = await _getRun(runId);
    if (run == null) return;
    await _refreshRunFromTasks(run);
  }

  Future<void> markTaskStarted({
    required String runId,
    required String taskId,
    required String taskType,
  }) async {
    final run = await _getRun(runId);
    if (run == null) return;
    final stage = _stageForTask(taskType);
    final now = _nowSeconds();
    await (_db.update(_db.agentRuns)..where((r) => r.id.equals(runId))).write(
      AgentRunsCompanion(
        state: Value(_dbState(AgentRunState.running)),
        stage: Value(stage.title),
        message: Value(stage.startedMessage),
        completedUnits: Value(_maxUnit(run.completedUnits, stage.startedUnits)),
        totalUnits: const Value(defaultTotalUnits),
        currentTaskId: Value(taskId),
        currentTaskType: Value(taskType),
        lastError: const Value(null),
        remainingTasks: Value(await _activeTaskCount(runId)),
        updatedAt: Value(now),
        completedAt: const Value(null),
      ),
    );
  }

  Future<void> markTaskRetrying({
    required String runId,
    required String taskId,
    required String taskType,
    required Object error,
  }) async {
    final run = await _getRun(runId);
    if (run == null) return;
    final now = _nowSeconds();
    await (_db.update(_db.agentRuns)..where((r) => r.id.equals(runId))).write(
      AgentRunsCompanion(
        state: Value(_dbState(AgentRunState.queued)),
        stage: const Value('Waiting to retry'),
        message: const Value('The current step will retry automatically.'),
        currentTaskId: Value(taskId),
        currentTaskType: Value(taskType),
        lastError: Value(_trimError(error)),
        remainingTasks: Value(await _activeTaskCount(runId)),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> markTaskFailed({
    required String runId,
    required String taskId,
    required String taskType,
    required Object error,
  }) async {
    final now = _nowSeconds();
    await (_db.update(_db.agentRuns)..where((r) => r.id.equals(runId))).write(
      AgentRunsCompanion(
        state: Value(_dbState(AgentRunState.failed)),
        stage: const Value('Needs attention'),
        message: Value(_trimError(error)),
        currentTaskId: Value(taskId),
        currentTaskType: Value(taskType),
        lastError: Value(_trimError(error)),
        remainingTasks: Value(await _activeTaskCount(runId)),
        updatedAt: Value(now),
        completedAt: Value(now),
      ),
    );
  }

  Future<void> markTaskCompleted({
    required String runId,
    required String taskId,
    required String taskType,
  }) async {
    final run = await _getRun(runId);
    if (run == null) return;
    final stage = _stageForTask(taskType);
    final now = _nowSeconds();
    await (_db.update(_db.agentRuns)..where((r) => r.id.equals(runId))).write(
      AgentRunsCompanion(
        completedUnits:
            Value(_maxUnit(run.completedUnits, stage.completedUnits)),
        currentTaskId: Value(taskId),
        currentTaskType: Value(taskType),
        remainingTasks: Value(await _activeTaskCount(runId)),
        updatedAt: Value(now),
      ),
    );
    final updatedRun = await _getRun(runId);
    if (updatedRun != null) {
      await _refreshRunFromTasks(updatedRun);
    }
  }

  Future<void> markActiveRunsPausedBySystem({
    String? userId,
    required String message,
  }) async {
    final query = _db.select(_db.agentRuns)
      ..where((run) => run.state.isIn([
            _dbState(AgentRunState.queued),
            _dbState(AgentRunState.running),
          ]));
    if (userId != null && userId.isNotEmpty) {
      query.where((run) => run.userId.equals(userId));
    }
    final runs = await query.get();
    final now = _nowSeconds();
    for (final run in runs) {
      await (_db.update(_db.agentRuns)..where((r) => r.id.equals(run.id)))
          .write(
        AgentRunsCompanion(
          state: Value(_dbState(AgentRunState.pausedBySystem)),
          stage: const Value('Paused'),
          message: Value(message),
          remainingTasks: Value(await _activeTaskCount(run.id)),
          updatedAt: Value(now),
        ),
      );
    }
  }

  Future<void> resumePausedRunIfNeeded(String runId) async {
    final run = await _getRun(runId);
    if (run == null || run.state != _dbState(AgentRunState.pausedBySystem)) {
      return;
    }
    await _refreshRunFromTasks(run);
  }

  Future<AgentRun?> _getRun(String runId) {
    return (_db.select(_db.agentRuns)..where((run) => run.id.equals(runId)))
        .getSingleOrNull();
  }

  Future<void> _refreshRunFromTasks(AgentRun run) async {
    final tasks = await (_db.select(_db.tasks)
          ..where((task) => task.runId.equals(run.id)))
        .get();
    if (tasks.isEmpty) return;

    final activeTasks = tasks
        .where((task) =>
            const {'pending', 'processing', 'retrying'}.contains(task.status))
        .toList();
    final failedTasks = tasks.where((task) => task.status == 'failed').toList();
    final now = _nowSeconds();

    if (activeTasks.isEmpty) {
      final latestFailed = _latestTask(failedTasks);
      final latestCompleted = _latestTask(
        tasks.where((task) => task.status == 'completed').toList(),
      );
      final latestFailedTs =
          latestFailed == null ? -1 : _taskTerminalTimestamp(latestFailed);
      final latestCompletedTs = latestCompleted == null
          ? -1
          : _taskTerminalTimestamp(latestCompleted);

      if (latestFailed != null && latestFailedTs >= latestCompletedTs) {
        await (_db.update(_db.agentRuns)..where((r) => r.id.equals(run.id)))
            .write(
          AgentRunsCompanion(
            state: Value(_dbState(AgentRunState.failed)),
            stage: const Value('Needs attention'),
            message: Value(
              _trimNullable(latestFailed.error) ?? 'Processing failed.',
            ),
            lastError: Value(_trimNullable(latestFailed.error)),
            currentTaskId: Value(latestFailed.id),
            currentTaskType: Value(latestFailed.type),
            remainingTasks: const Value(0),
            updatedAt: Value(now),
            completedAt: Value(now),
          ),
        );
        return;
      }

      await (_db.update(_db.agentRuns)..where((r) => r.id.equals(run.id)))
          .write(
        AgentRunsCompanion(
          state: Value(_dbState(AgentRunState.completed)),
          stage: const Value('Completed'),
          message: const Value('All background work finished.'),
          completedUnits: const Value(defaultTotalUnits),
          remainingTasks: const Value(0),
          currentTaskId: const Value(null),
          currentTaskType: const Value(null),
          lastError: const Value(null),
          updatedAt: Value(now),
          completedAt: Value(now),
        ),
      );
      return;
    }

    final processing = activeTasks.where((task) => task.status == 'processing');
    final retrying = activeTasks.where((task) => task.status == 'retrying');
    final chosen = processing.isNotEmpty
        ? processing.first
        : retrying.isNotEmpty
            ? retrying.first
            : activeTasks.first;
    final stage = _stageForTask(chosen.type);
    final state = chosen.status == 'processing'
        ? AgentRunState.running
        : AgentRunState.queued;
    final visibleStage = chosen.status == 'retrying'
        ? 'Waiting to retry'
        : chosen.status == 'pending'
            ? 'Queued'
            : stage.title;
    final visibleUnits = chosen.status == 'processing'
        ? _maxUnit(run.completedUnits, stage.startedUnits)
        : run.completedUnits;
    final message = chosen.status == 'retrying'
        ? 'The current step will retry automatically.'
        : chosen.status == 'pending'
            ? 'Waiting for the next processing step.'
            : stage.startedMessage;

    await (_db.update(_db.agentRuns)..where((r) => r.id.equals(run.id))).write(
      AgentRunsCompanion(
        state: Value(_dbState(state)),
        stage: Value(visibleStage),
        message: Value(message),
        completedUnits: Value(visibleUnits),
        totalUnits: const Value(defaultTotalUnits),
        currentTaskId: Value(chosen.id),
        currentTaskType: Value(chosen.type),
        remainingTasks: Value(activeTasks.length),
        updatedAt: Value(now),
      ),
    );
  }

  Future<int> _activeTaskCount(String runId) async {
    final query = _db.selectOnly(_db.tasks)
      ..addColumns([_db.tasks.id.count()])
      ..where(_db.tasks.runId.equals(runId))
      ..where(_db.tasks.status.isIn(['pending', 'processing', 'retrying']));
    final row = await query.getSingle();
    return row.read(_db.tasks.id.count()) ?? 0;
  }
}

class _StageInfo {
  const _StageInfo({
    required this.title,
    required this.startedMessage,
    required this.startedUnits,
    required this.completedUnits,
  });

  final String title;
  final String startedMessage;
  final int startedUnits;
  final int completedUnits;
}

const _visibleDbStates = [
  'queued',
  'running',
  'paused_by_system',
  'failed',
];

AgentRunState _stateFromDb(String value) {
  return switch (value) {
    'queued' => AgentRunState.queued,
    'running' => AgentRunState.running,
    'paused_by_system' => AgentRunState.pausedBySystem,
    'completed' => AgentRunState.completed,
    'failed' => AgentRunState.failed,
    _ => AgentRunState.queued,
  };
}

String _dbState(AgentRunState state) {
  return switch (state) {
    AgentRunState.queued => 'queued',
    AgentRunState.running => 'running',
    AgentRunState.pausedBySystem => 'paused_by_system',
    AgentRunState.completed => 'completed',
    AgentRunState.failed => 'failed',
  };
}

_StageInfo _stageForTask(String taskType) {
  return switch (taskType) {
    'handle_analyze_assets' => const _StageInfo(
        title: 'Analyzing media',
        startedMessage: 'Reading attachments and local context.',
        startedUnits: 10,
        completedUnits: 25,
      ),
    'card_agent_task' => const _StageInfo(
        title: 'Generating card',
        startedMessage: 'Turning the record into a timeline card.',
        startedUnits: 30,
        completedUnits: 60,
      ),
    'pkm_agent_task' => const _StageInfo(
        title: 'Updating knowledge',
        startedMessage: 'Updating local knowledge and memory.',
        startedUnits: 65,
        completedUnits: 78,
      ),
    'comment_agent_task' => const _StageInfo(
        title: 'Preparing comment',
        startedMessage: 'Preparing an assistant follow-up.',
        startedUnits: 80,
        completedUnits: 88,
      ),
    'post_card_router_task' => const _StageInfo(
        title: 'Routing follow-ups',
        startedMessage: 'Checking follow-up actions for this card.',
        startedUnits: 90,
        completedUnits: 96,
      ),
    _ => const _StageInfo(
        title: 'Processing',
        startedMessage: 'Memex is processing background work.',
        startedUnits: 20,
        completedUnits: 90,
      ),
  };
}

bool _sameSnapshot(AgentRunSnapshot? a, AgentRunSnapshot? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.id == b.id &&
      a.state == b.state &&
      a.stage == b.stage &&
      a.message == b.message &&
      a.completedUnits == b.completedUnits &&
      a.totalUnits == b.totalUnits &&
      a.remainingTasks == b.remainingTasks &&
      a.currentTaskId == b.currentTaskId &&
      a.currentTaskType == b.currentTaskType &&
      a.lastError == b.lastError;
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

int _maxUnit(int left, int right) => left > right ? left : right;

Task? _latestTask(List<Task> tasks) {
  if (tasks.isEmpty) return null;
  return tasks.reduce((a, b) {
    return _taskTerminalTimestamp(a) >= _taskTerminalTimestamp(b) ? a : b;
  });
}

int _taskTerminalTimestamp(Task task) {
  return task.completedAt ?? task.updatedAt ?? task.createdAt ?? 0;
}

String _trimError(Object error) {
  return _trimNullable(error.toString()) ?? 'Processing failed.';
}

String? _trimNullable(String? value) {
  final compact = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (compact == null || compact.isEmpty) return null;
  if (compact.length <= 180) return compact;
  return '${compact.substring(0, 177)}...';
}
