import 'package:memex/data/services/agent_activity_service.dart';
import 'package:memex/data/services/local_task_executor.dart';
import 'package:memex/l10n/app_localizations.dart';

enum AgentBackgroundRunState { idle, active, completed, failed }

class AgentBackgroundStatus {
  const AgentBackgroundStatus({
    required this.state,
    required this.pending,
    required this.processing,
    required this.retrying,
    required this.title,
    required this.stage,
    required this.detail,
    required this.summary,
    required this.agentName,
    required this.updatedAt,
    this.scene,
    this.sceneId,
  });

  factory AgentBackgroundStatus.fromActivity({
    required TaskActivitySnapshot taskSnapshot,
    AgentActivityMessageModel? latestMessage,
    DateTime? now,
    AgentBackgroundStatusLabels labels = const AgentBackgroundStatusLabels(),
  }) {
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
      AgentBackgroundRunState.failed => labels.needsAttention,
      AgentBackgroundRunState.completed => labels.completed,
      AgentBackgroundRunState.active => labels.processing,
      AgentBackgroundRunState.idle => labels.idle,
    };

    final title = switch (state) {
      AgentBackgroundRunState.failed => labels.needsAttentionTitle,
      AgentBackgroundRunState.completed => labels.title,
      AgentBackgroundRunState.active => labels.title,
      AgentBackgroundRunState.idle => labels.title,
    };

    final stage =
        _firstNonBlank([latestMessage?.title, latestMessage?.agentName]) ??
            fallbackStage;

    final detail = _detailFor(
      taskSnapshot: taskSnapshot,
      latestMessage: latestMessage,
      state: state,
      labels: labels,
    );
    final summary = _summaryFor(
      taskSnapshot: taskSnapshot,
      latestMessage: latestMessage,
      fallbackStage: fallbackStage,
      detail: detail,
      labels: labels,
    );

    return AgentBackgroundStatus(
      state: state,
      pending: taskSnapshot.pending,
      processing: taskSnapshot.processing,
      retrying: taskSnapshot.retrying,
      title: title,
      stage: stage,
      detail: detail,
      summary: summary,
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
  final String summary;
  final String agentName;
  final String? scene;
  final String? sceneId;
  final DateTime updatedAt;

  int get remainingTasks => pending + processing + retrying;

  bool get hasActiveTasks => remainingTasks > 0;

  bool get shouldShowSystemSurface =>
      state == AgentBackgroundRunState.active ||
      state == AgentBackgroundRunState.failed;

  Map<String, dynamic> toPlatformMap({bool isInBackground = false}) {
    return {
      'state': state.name,
      'pending': pending,
      'processing': processing,
      'retrying': retrying,
      'remainingTasks': remainingTasks,
      'title': title,
      'stage': stage,
      'detail': detail,
      'summary': summary,
      'agentName': agentName,
      'scene': scene,
      'sceneId': sceneId,
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
        other.summary == summary &&
        other.agentName == agentName &&
        other.scene == scene &&
        other.sceneId == sceneId;
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
        summary,
        agentName,
        scene,
        sceneId,
      );
}

class AgentBackgroundStatusLabels {
  const AgentBackgroundStatusLabels({
    this.title = 'Memex Agent',
    this.needsAttentionTitle = 'Memex Agent needs attention',
    this.processing = 'Processing',
    this.needsAttention = 'Needs attention',
    this.completed = 'Completed',
    this.idle = 'Idle',
    this.processingStarting = 'Processing is starting.',
    this.processingStoppedWithError = 'Processing stopped with an error.',
    this.allBackgroundTasksFinished = 'All background tasks finished.',
    this.noBackgroundTasks = 'No background tasks.',
    this.processingQueuedTasks = _defaultProcessingQueuedTasks,
  });

  factory AgentBackgroundStatusLabels.fromL10n(AppLocalizations l10n) {
    return AgentBackgroundStatusLabels(
      title: l10n.agentBackgroundTitle,
      needsAttentionTitle: l10n.agentBackgroundNeedsAttentionTitle,
      processing: l10n.agentBackgroundProcessing,
      needsAttention: l10n.agentBackgroundNeedsAttention,
      completed: l10n.agentBackgroundCompleted,
      idle: l10n.agentBackgroundIdle,
      processingStarting: l10n.agentBackgroundProcessingStarting,
      processingStoppedWithError: l10n.agentBackgroundStoppedWithError,
      allBackgroundTasksFinished: l10n.agentBackgroundAllTasksFinished,
      noBackgroundTasks: l10n.agentBackgroundNoTasks,
      processingQueuedTasks: l10n.agentBackgroundQueuedTasks,
    );
  }

  final String title;
  final String needsAttentionTitle;
  final String processing;
  final String needsAttention;
  final String completed;
  final String idle;
  final String processingStarting;
  final String processingStoppedWithError;
  final String allBackgroundTasksFinished;
  final String noBackgroundTasks;
  final String Function(num count) processingQueuedTasks;
}

String _detailFor({
  required TaskActivitySnapshot taskSnapshot,
  required AgentActivityMessageModel? latestMessage,
  required AgentBackgroundRunState state,
  required AgentBackgroundStatusLabels labels,
}) {
  final messageContent = _trimToSingleLine(latestMessage?.content);
  if (messageContent != null) return messageContent;

  if (taskSnapshot.hasActiveTasks) {
    return labels.processingQueuedTasks(taskSnapshot.total);
  }

  return switch (state) {
    AgentBackgroundRunState.failed => labels.processingStoppedWithError,
    AgentBackgroundRunState.completed => labels.allBackgroundTasksFinished,
    AgentBackgroundRunState.active => labels.processingStarting,
    AgentBackgroundRunState.idle => labels.noBackgroundTasks,
  };
}

String _summaryFor({
  required TaskActivitySnapshot taskSnapshot,
  required AgentActivityMessageModel? latestMessage,
  required String fallbackStage,
  required String detail,
  required AgentBackgroundStatusLabels labels,
}) {
  final messageTitle = _firstNonBlank([
    latestMessage?.title,
    latestMessage?.agentName,
  ]);
  final messageContent = _trimToSingleLine(latestMessage?.content);
  if (messageContent != null) {
    return messageContent;
  }
  if (messageTitle != null) return messageTitle;
  if (taskSnapshot.hasActiveTasks) {
    return labels.processingQueuedTasks(taskSnapshot.total);
  }
  if (detail.isNotBlank) return detail;
  return fallbackStage;
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String? _trimToSingleLine(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final compact = trimmed.replaceAll(RegExp(r'\s+'), ' ');
  if (compact.length <= 140) return compact;
  return '${compact.substring(0, 137)}...';
}

String _defaultProcessingQueuedTasks(num count) {
  return 'Processing $count queued ${count == 1 ? 'task' : 'tasks'}';
}

extension on String {
  bool get isNotBlank => trim().isNotEmpty;
}
