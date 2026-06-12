import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/l10n/app_localizations_ext.dart';
import 'package:memex/utils/user_storage.dart';

enum AgentBackgroundRunState { idle, active, paused, completed, failed }

class AgentBackgroundStatus {
  const AgentBackgroundStatus({
    required this.state,
    required this.pending,
    required this.processing,
    required this.retrying,
    required this.title,
    required this.stage,
    required this.detail,
    required this.agentName,
    required this.updatedAt,
    this.progressCompleted = 0,
    this.progressTotal = 0,
    this.runId,
    this.factId,
    this.scene,
    this.sceneId,
  });

  factory AgentBackgroundStatus.fromActivity({
    required TaskActivitySnapshot taskSnapshot,
    AgentActivityMessageModel? latestMessage,
    AgentRunSnapshot? runSnapshot,
    DateTime? now,
  }) {
    if (runSnapshot != null) {
      return _fromRunSnapshot(
        runSnapshot: runSnapshot,
        taskSnapshot: taskSnapshot,
        latestMessage: latestMessage,
        now: now,
      );
    }

    final messageType = latestMessage?.type;
    final hasTasks = taskSnapshot.hasActiveTasks;
    final state = switch (messageType) {
      AgentActivityType.error when !hasTasks => AgentBackgroundRunState.failed,
      AgentActivityType.agent_stop when !hasTasks =>
        AgentBackgroundRunState.completed,
      _ when hasTasks => AgentBackgroundRunState.active,
      _ => AgentBackgroundRunState.idle,
    };

    final fallbackStage = switch (state) {
      AgentBackgroundRunState.failed => _text(
          (l10n) => l10n.agentBackgroundStageNeedsAttention,
          'Needs attention',
        ),
      AgentBackgroundRunState.completed => _text(
          (l10n) => l10n.agentBackgroundStageCompleted,
          'Completed',
        ),
      AgentBackgroundRunState.paused => _text(
          (l10n) => l10n.agentBackgroundStagePaused,
          'Paused',
        ),
      AgentBackgroundRunState.active => _text(
          (l10n) => l10n.agentBackgroundStageProcessing,
          'Processing',
        ),
      AgentBackgroundRunState.idle => _text(
          (l10n) => l10n.agentBackgroundStageIdle,
          'Idle',
        ),
    };

    final title = _titleForState(state);

    final stage = _localizeKnownStatusText(_firstNonBlank([
          latestMessage?.title,
          latestMessage?.agentName,
        ])) ??
        fallbackStage;

    final detail = _detailFor(
      taskSnapshot: taskSnapshot,
      latestMessage: latestMessage,
      state: state,
    );

    return AgentBackgroundStatus(
      state: state,
      pending: taskSnapshot.pending,
      processing: taskSnapshot.processing,
      retrying: taskSnapshot.retrying,
      title: title,
      stage: stage,
      detail: detail,
      agentName: latestMessage?.agentName ?? '',
      scene: latestMessage?.scene,
      sceneId: latestMessage?.sceneId,
      updatedAt: now ?? DateTime.now(),
    );
  }

  final AgentBackgroundRunState state;
  final int pending;
  final int processing;
  final int retrying;
  final String title;
  final String stage;
  final String detail;
  final String agentName;
  final String? scene;
  final String? sceneId;
  final DateTime updatedAt;
  final int progressCompleted;
  final int progressTotal;
  final String? runId;
  final String? factId;

  int get remainingTasks => pending + processing + retrying;

  bool get hasActiveTasks => remainingTasks > 0;

  String get taskSummary => formatAgentTaskSummary(
        pending: pending,
        processing: processing,
        retrying: retrying,
      );

  String get statusText {
    final summary = taskSummary;
    return switch (state) {
      AgentBackgroundRunState.failed => remainingTasks > 0
          ? _text(
              (l10n) => l10n.agentBackgroundNeedsAttentionStatus(summary),
              'Needs attention - $summary',
            )
          : _text(
              (l10n) => l10n.agentBackgroundStageNeedsAttention,
              'Needs attention',
            ),
      AgentBackgroundRunState.paused => remainingTasks > 0
          ? _text(
              (l10n) => l10n.agentBackgroundPausedStatus(summary),
              'Paused - $summary',
            )
          : _text(
              (l10n) => l10n.agentBackgroundPausedDetail,
              'Paused - will continue later',
            ),
      AgentBackgroundRunState.active => remainingTasks > 0
          ? summary
          : _text(
              (l10n) => l10n.agentBackgroundStageProcessing,
              'Processing',
            ),
      AgentBackgroundRunState.completed => _text(
          (l10n) => l10n.agentBackgroundStageCompleted,
          'Completed',
        ),
      AgentBackgroundRunState.idle => _text(
          (l10n) => l10n.agentBackgroundStageIdle,
          'Idle',
        ),
    };
  }

  bool get shouldShowSystemSurface =>
      state == AgentBackgroundRunState.active ||
      state == AgentBackgroundRunState.paused ||
      state == AgentBackgroundRunState.failed;

  Map<String, dynamic> toPlatformMap({bool isInBackground = false}) {
    return {
      'state': state.name,
      'pending': pending,
      'processing': processing,
      'retrying': retrying,
      'remainingTasks': remainingTasks,
      'taskSummary': taskSummary,
      'statusText': statusText,
      'title': title,
      'stage': stage,
      'detail': detail,
      'agentName': agentName,
      'scene': scene,
      'sceneId': sceneId,
      'runId': runId,
      'factId': factId,
      'progressCompleted': progressCompleted,
      'progressTotal': progressTotal,
      'updatedAtMs': updatedAt.millisecondsSinceEpoch,
      'isInBackground': isInBackground,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is AgentBackgroundStatus &&
        other.state == state &&
        other.pending == pending &&
        other.processing == processing &&
        other.retrying == retrying &&
        other.title == title &&
        other.stage == stage &&
        other.detail == detail &&
        other.agentName == agentName &&
        other.scene == scene &&
        other.sceneId == sceneId &&
        other.progressCompleted == progressCompleted &&
        other.progressTotal == progressTotal &&
        other.runId == runId &&
        other.factId == factId;
  }

  @override
  int get hashCode => Object.hash(
        state,
        pending,
        processing,
        retrying,
        title,
        stage,
        detail,
        agentName,
        scene,
        sceneId,
        progressCompleted,
        progressTotal,
        runId,
        factId,
      );
}

AgentBackgroundStatus _fromRunSnapshot({
  required AgentRunSnapshot runSnapshot,
  required TaskActivitySnapshot taskSnapshot,
  required AgentActivityMessageModel? latestMessage,
  DateTime? now,
}) {
  final state = switch (runSnapshot.state) {
    AgentRunState.queued ||
    AgentRunState.running =>
      AgentBackgroundRunState.active,
    AgentRunState.pausedBySystem => AgentBackgroundRunState.paused,
    AgentRunState.completed => AgentBackgroundRunState.completed,
    AgentRunState.failed => AgentBackgroundRunState.failed,
  };

  final fallbackTitle = _titleForState(state);

  final fallbackDetail = _detailFor(
    taskSnapshot: taskSnapshot,
    latestMessage: latestMessage,
    state: state,
  );
  final pending = taskSnapshot.total == 0
      ? runSnapshot.remainingTasks
      : taskSnapshot.pending;

  return AgentBackgroundStatus(
    state: state,
    pending: pending,
    processing: taskSnapshot.processing,
    retrying: taskSnapshot.retrying,
    title: fallbackTitle,
    stage: _localizeKnownStatusText(runSnapshot.stage) ?? runSnapshot.stage,
    detail: _trimToSingleLine(
          _localizeKnownStatusText(runSnapshot.message) ?? runSnapshot.message,
        ) ??
        fallbackDetail,
    agentName: latestMessage?.agentName ?? '',
    scene: latestMessage?.scene,
    sceneId: latestMessage?.sceneId ?? runSnapshot.factId,
    updatedAt: now ?? runSnapshot.updatedAt,
    progressCompleted: runSnapshot.completedUnits,
    progressTotal: runSnapshot.totalUnits,
    runId: runSnapshot.id,
    factId: runSnapshot.factId,
  );
}

String _detailFor({
  required TaskActivitySnapshot taskSnapshot,
  required AgentActivityMessageModel? latestMessage,
  required AgentBackgroundRunState state,
}) {
  final messageContent = _trimToSingleLine(latestMessage?.content);
  if (messageContent != null) return messageContent;

  if (taskSnapshot.hasActiveTasks) {
    return _text(
      (l10n) => l10n.agentBackgroundTaskDetail(taskSnapshot.total),
      'Processing ${taskSnapshot.total} queued task(s).',
    );
  }

  return switch (state) {
    AgentBackgroundRunState.failed => _text(
        (l10n) => l10n.agentBackgroundFailedDetail,
        'Processing stopped with an error.',
      ),
    AgentBackgroundRunState.completed => _text(
        (l10n) => l10n.agentBackgroundCompletedDetail,
        'All background tasks finished.',
      ),
    AgentBackgroundRunState.paused => _text(
        (l10n) => l10n.agentBackgroundPausedDetail,
        'Processing is paused and will continue later.',
      ),
    AgentBackgroundRunState.active => _text(
        (l10n) => l10n.agentBackgroundStarting,
        'Processing is starting.',
      ),
    AgentBackgroundRunState.idle => _text(
        (l10n) => l10n.agentBackgroundNoTasks,
        'No background tasks.',
      ),
  };
}

String formatAgentTaskSummary({
  required int pending,
  required int processing,
  required int retrying,
}) {
  return _text(
    (l10n) => l10n.agentBackgroundTaskSummary(processing, pending, retrying),
    'Running $processing, Pending $pending, Retry $retrying',
  );
}

String _titleForState(AgentBackgroundRunState state) {
  return switch (state) {
    AgentBackgroundRunState.failed => _text(
        (l10n) => l10n.agentBackgroundNeedsAttentionTitle,
        'Memex Agent needs attention',
      ),
    AgentBackgroundRunState.paused => _text(
        (l10n) => l10n.agentBackgroundPausedTitle,
        'Memex Agent paused',
      ),
    AgentBackgroundRunState.completed ||
    AgentBackgroundRunState.active ||
    AgentBackgroundRunState.idle =>
      _text((l10n) => l10n.agentBackgroundTitle, 'Memex Agent'),
  };
}

String? _localizeKnownStatusText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return switch (trimmed) {
    'Idle' => _text((l10n) => l10n.agentBackgroundStageIdle, trimmed),
    'Processing' =>
      _text((l10n) => l10n.agentBackgroundStageProcessing, trimmed),
    'Queued' => _text((l10n) => l10n.agentBackgroundStageQueued, trimmed),
    'Waiting to retry' =>
      _text((l10n) => l10n.agentBackgroundStageRetrying, trimmed),
    'Paused' => _text((l10n) => l10n.agentBackgroundStagePaused, trimmed),
    'Completed' => _text((l10n) => l10n.agentBackgroundStageCompleted, trimmed),
    'Needs attention' =>
      _text((l10n) => l10n.agentBackgroundStageNeedsAttention, trimmed),
    'Analyzing media' =>
      _text((l10n) => l10n.agentBackgroundStageAnalyzingMedia, trimmed),
    'Generating card' =>
      _text((l10n) => l10n.agentBackgroundStageGeneratingCard, trimmed),
    'Updating knowledge' =>
      _text((l10n) => l10n.agentBackgroundStageUpdatingKnowledge, trimmed),
    'Preparing comment' =>
      _text((l10n) => l10n.agentBackgroundStagePreparingComment, trimmed),
    'Routing follow-ups' =>
      _text((l10n) => l10n.agentBackgroundStageRoutingFollowUps, trimmed),
    'No background tasks.' =>
      _text((l10n) => l10n.agentBackgroundNoTasks, trimmed),
    'Processing is starting.' =>
      _text((l10n) => l10n.agentBackgroundStarting, trimmed),
    'All background tasks finished.' =>
      _text((l10n) => l10n.agentBackgroundCompletedDetail, trimmed),
    'Processing stopped with an error.' =>
      _text((l10n) => l10n.agentBackgroundFailedDetail, trimmed),
    'Processing is paused and will continue later.' =>
      _text((l10n) => l10n.agentBackgroundPausedDetail, trimmed),
    'Background time expired. Memex will continue later.' ||
    'iOS paused background processing. Memex will continue later.' =>
      _text((l10n) => l10n.agentBackgroundPausedDetail, trimmed),
    'Waiting for the next processing step.' =>
      _text((l10n) => l10n.agentBackgroundQueuedDetail, trimmed),
    'Waiting for background processing to start.' ||
    'Waiting for the next background window.' =>
      _text((l10n) => l10n.agentBackgroundQueuedDetail, trimmed),
    'The current step will retry automatically.' =>
      _text((l10n) => l10n.agentBackgroundRetryingDetail, trimmed),
    'Reading attachments and local context.' =>
      _text((l10n) => l10n.agentBackgroundAnalyzeMediaDetail, trimmed),
    'Turning the record into a timeline card.' =>
      _text((l10n) => l10n.agentBackgroundGeneratingCardDetail, trimmed),
    'Updating local knowledge and memory.' =>
      _text((l10n) => l10n.agentBackgroundUpdatingKnowledgeDetail, trimmed),
    'Preparing an assistant follow-up.' =>
      _text((l10n) => l10n.agentBackgroundPreparingCommentDetail, trimmed),
    'Checking follow-up actions for this card.' =>
      _text((l10n) => l10n.agentBackgroundRoutingFollowUpsDetail, trimmed),
    _ => trimmed,
  };
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _text(
  String Function(AppLocalizationsExt l10n) builder,
  String fallback,
) {
  try {
    return builder(UserStorage.l10n);
  } catch (_) {
    return fallback;
  }
}

String? _trimToSingleLine(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final compact = trimmed.replaceAll(RegExp(r'\s+'), ' ');
  if (compact.length <= 140) return compact;
  return '${compact.substring(0, 137)}...';
}
