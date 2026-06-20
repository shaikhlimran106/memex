import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';
import 'package:memex/data/services/agent_queue_drain_scheduler.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

class AgentBackgroundCoordinator with WidgetsBindingObserver {
  AgentBackgroundCoordinator({
    AgentBackgroundPlatform? platform,
    AgentQueueDrainScheduler? scheduler,
    AgentRunService? runService,
    AppLifecycleState? initialLifecycleState,
  })  : _platform = platform ?? MethodChannelAgentBackgroundPlatform(),
        _scheduler = scheduler ?? WorkmanagerAgentQueueDrainScheduler(),
        _runService = runService ?? AgentRunService.instance,
        _initialLifecycleState = initialLifecycleState;

  static AgentBackgroundCoordinator? _instance;
  static AgentBackgroundCoordinator get instance {
    _instance ??= AgentBackgroundCoordinator();
    return _instance!;
  }

  final AgentBackgroundPlatform _platform;
  final AgentQueueDrainScheduler _scheduler;
  final AgentRunService _runService;
  final _logger = getLogger('AgentBackgroundCoordinator');

  StreamSubscription<TaskActivitySnapshot>? _taskSubscription;
  StreamSubscription<AgentActivityMessageModel>? _messageSubscription;
  StreamSubscription<AgentRunSnapshot?>? _runSubscription;
  StreamSubscription<String>? _actionSubscription;
  late final StreamController<void> _openActivityController =
      StreamController<void>.broadcast(
    onListen: _flushPendingOpenActivityRequest,
  );

  TaskActivitySnapshot _taskSnapshot = const TaskActivitySnapshot.empty();
  AgentActivityMessageModel? _latestMessage;
  AgentRunSnapshot? _runSnapshot;
  AgentBackgroundStatus? _lastPublishedStatus;
  bool? _lastPublishedIsInBackground;
  Future<void> _publishChain = Future<void>.value();
  Timer? _terminalStopTimer;
  bool _started = false;
  bool _drainWorkScheduledForCurrentRun = false;
  bool _hasPendingOpenActivityRequest = false;
  final AppLifecycleState? _initialLifecycleState;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _publishGeneration = 0;

  Stream<void> get openActivityRequests => _openActivityController.stream;

  void start({
    required LocalTaskExecutor executor,
    required AgentActivityService activityService,
  }) {
    if (_started || !_platform.isSupported) return;
    _started = true;
    _lifecycleState = _initialLifecycleState ??
        WidgetsBinding.instance.lifecycleState ??
        AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);

    _taskSubscription = executor.taskActivitySnapshotStream.listen(
      _handleTaskSnapshot,
    );
    _messageSubscription = activityService.messageStream.listen(
      _handleActivityMessage,
    );
    _runSubscription = _runService.watchLatestVisibleRun().listen(
          _handleRunSnapshot,
        );
    _actionSubscription = _platform.actionStream.listen(_handleAction);

    unawaited(_consumeInitialAction());
    _queuePublishStatus();
  }

  Future<void> stop() async {
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _terminalStopTimer?.cancel();
    _terminalStopTimer = null;
    await _taskSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _runSubscription?.cancel();
    await _actionSubscription?.cancel();
    _taskSubscription = null;
    _messageSubscription = null;
    _runSubscription = null;
    _actionSubscription = null;
    _taskSnapshot = const TaskActivitySnapshot.empty();
    _latestMessage = null;
    _runSnapshot = null;
    _lastPublishedStatus = null;
    _lastPublishedIsInBackground = null;
    _drainWorkScheduledForCurrentRun = false;
    _publishGeneration++;
    await _safeStopPlatform();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _queuePublishStatus();
    if (_started &&
        state != AppLifecycleState.resumed &&
        _taskSnapshot.hasActiveTasks) {
      unawaited(_scheduleDrainIfNeeded());
    }
  }

  void _handleTaskSnapshot(TaskActivitySnapshot snapshot) {
    _taskSnapshot = snapshot;
    if (!snapshot.hasActiveTasks) {
      _drainWorkScheduledForCurrentRun = false;
    }
    _queuePublishStatus();
  }

  void _handleActivityMessage(AgentActivityMessageModel message) {
    _latestMessage = message;
    _queuePublishStatus();
  }

  void _handleRunSnapshot(AgentRunSnapshot? snapshot) {
    _runSnapshot = snapshot;
    _queuePublishStatus();
  }

  void _handleAction(String action) {
    if (action == 'agent_activity') {
      if (_openActivityController.hasListener) {
        _openActivityController.add(null);
      } else {
        _hasPendingOpenActivityRequest = true;
      }
    }
  }

  void _flushPendingOpenActivityRequest() {
    if (!_hasPendingOpenActivityRequest) return;
    _hasPendingOpenActivityRequest = false;
    scheduleMicrotask(() {
      if (!_openActivityController.isClosed) {
        _openActivityController.add(null);
      }
    });
  }

  Future<void> _consumeInitialAction() async {
    try {
      final action = await _platform.consumeInitialAction();
      if (action != null) _handleAction(action);
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to consume initial background action',
        e,
        stackTrace,
      );
    }
  }

  void _queuePublishStatus() {
    if (!_started) return;
    final generation = ++_publishGeneration;
    _publishChain = _publishChain.then((_) => _publishStatus(generation));
    unawaited(_publishChain);
  }

  Future<void> _publishStatus(int generation) async {
    if (!_started || generation != _publishGeneration) return;

    final status = AgentBackgroundStatus.fromActivity(
      taskSnapshot: _taskSnapshot,
      latestMessage: _latestMessage,
      runSnapshot: _runSnapshot,
      labels: _statusLabels(),
    );
    final isInBackground = _lifecycleState != AppLifecycleState.resumed;

    if (!_started || generation != _publishGeneration) return;
    if (status == _lastPublishedStatus &&
        isInBackground == _lastPublishedIsInBackground) {
      return;
    }
    final previousPublishedStatus = _lastPublishedStatus;
    final previousPublishedIsInBackground = _lastPublishedIsInBackground;
    _lastPublishedStatus = status;
    _lastPublishedIsInBackground = isInBackground;

    _terminalStopTimer?.cancel();
    _terminalStopTimer = null;

    try {
      if (status.state == AgentBackgroundRunState.idle) {
        await _safeStopPlatform();
        await _scheduler.cancel();
        return;
      }

      if (status.state == AgentBackgroundRunState.active) {
        await _platform.updateStatus(status, isInBackground: isInBackground);
        if (!_started || generation != _publishGeneration) return;
        await _scheduleDrainIfNeeded();
        return;
      }

      if (status.state == AgentBackgroundRunState.paused) {
        await _platform.updateStatus(status, isInBackground: isInBackground);
        return;
      }

      if (status.state == AgentBackgroundRunState.completed) {
        await _scheduler.cancel();
        await _safeStopPlatform();
        return;
      }

      await _platform.finishStatus(status, isInBackground: isInBackground);
      if (!_started || generation != _publishGeneration) return;
      await _scheduler.cancel();
      _terminalStopTimer = Timer(const Duration(seconds: 5), () {
        unawaited(_safeStopPlatform());
      });
    } catch (e, stackTrace) {
      _lastPublishedStatus = previousPublishedStatus;
      _lastPublishedIsInBackground = previousPublishedIsInBackground;
      if (status.state == AgentBackgroundRunState.active) {
        _drainWorkScheduledForCurrentRun = false;
      }
      _logger.warning(
        'Failed to publish agent background status',
        e,
        stackTrace,
      );
    }
  }

  Future<void> _safeStopPlatform() async {
    try {
      await _platform.stopStatus();
    } catch (e, stackTrace) {
      _logger.fine('Failed to stop agent background surface', e, stackTrace);
    }
  }

  Future<void> _scheduleDrainIfNeeded() async {
    if (!_started ||
        _drainWorkScheduledForCurrentRun ||
        _lifecycleState == AppLifecycleState.resumed) {
      return;
    }

    _drainWorkScheduledForCurrentRun = true;
    try {
      await _scheduler.schedule(expedited: true);
    } catch (e, stackTrace) {
      _drainWorkScheduledForCurrentRun = false;
      _logger.warning('Failed to schedule agent queue drain', e, stackTrace);
    }
  }

  AgentBackgroundStatusLabels _statusLabels() {
    try {
      return AgentBackgroundStatusLabels.fromL10n(UserStorage.l10n);
    } catch (_) {
      return const AgentBackgroundStatusLabels();
    }
  }
}

@visibleForTesting
void resetAgentBackgroundCoordinatorForTesting() {
  AgentBackgroundCoordinator._instance = null;
}

@visibleForTesting
void setAgentBackgroundCoordinatorForTesting(
  AgentBackgroundCoordinator coordinator,
) {
  AgentBackgroundCoordinator._instance = coordinator;
}

@visibleForTesting
void emitAgentBackgroundOpenActivityForTesting() {
  AgentBackgroundCoordinator.instance._handleAction('agent_activity');
}
