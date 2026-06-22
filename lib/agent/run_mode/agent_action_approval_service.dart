import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:logging/logging.dart';
import 'package:memex/agent/run_mode/agent_run_mode.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('AgentActionApprovalService');

/// A pending approval request for one mutating tool call.
class AgentActionApprovalRequest {
  AgentActionApprovalRequest({
    required this.id,
    required this.sessionId,
    required this.toolName,
    required this.summary,
    this.details = const {},
  });

  final String id;
  final String sessionId;
  final String toolName;

  /// Human-readable one-line description of what the tool is about to do
  /// (content snippet, file path, card title, ...). Data, not a UI label.
  final String summary;

  /// Optional structured details for the approval card UI.
  final Map<String, String> details;

  final Completer<bool> _completer = Completer<bool>();
}

/// Coordinates ask-first ([AgentRunMode.confirm]) approvals between tool
/// executables (which block until resolved) and the chat UI (which renders
/// approval cards and resolves them).
class AgentActionApprovalService {
  AgentActionApprovalService._();

  static final AgentActionApprovalService instance =
      AgentActionApprovalService._();

  final _uuid = const Uuid();
  final Map<String, AgentActionApprovalRequest> _pending = {};
  final Set<String> _attachedSessions = {};
  final StreamController<AgentActionApprovalRequest> _requestsController =
      StreamController<AgentActionApprovalRequest>.broadcast();

  /// New approval requests, for the chat UI to render.
  Stream<AgentActionApprovalRequest> get requests => _requestsController.stream;

  /// Marks a chat session as having an attached UI that can answer requests.
  void attachSession(String sessionId) => _attachedSessions.add(sessionId);

  /// Detaches the UI from a session and denies anything still pending, so a
  /// blocked tool call never hangs after the dialog is closed.
  void detachSession(String sessionId) {
    _attachedSessions.remove(sessionId);
    final orphaned = _pending.values
        .where((request) => request.sessionId == sessionId)
        .map((request) => request.id)
        .toList();
    for (final id in orphaned) {
      resolve(id, approved: false);
    }
  }

  bool isSessionAttached(String sessionId) =>
      _attachedSessions.contains(sessionId);

  /// Blocks until the user approves or denies. Returns false immediately when
  /// no UI is attached for [sessionId], and when [cancelToken] fires first.
  Future<bool> requestApproval({
    required String sessionId,
    required String toolName,
    required String summary,
    Map<String, String> details = const {},
    CancelToken? cancelToken,
  }) {
    if (!isSessionAttached(sessionId)) {
      _logger.warning(
        'Approval auto-denied for $toolName: no UI attached to $sessionId',
      );
      return Future.value(false);
    }

    final request = AgentActionApprovalRequest(
      id: _uuid.v4(),
      sessionId: sessionId,
      toolName: toolName,
      summary: summary,
      details: details,
    );
    _pending[request.id] = request;
    _requestsController.add(request);

    cancelToken?.whenCancel.then((_) {
      resolve(request.id, approved: false);
    });

    return request._completer.future;
  }

  /// Resolves a pending request. Safe to call multiple times.
  void resolve(String requestId, {required bool approved}) {
    final request = _pending.remove(requestId);
    if (request == null) return;
    if (!request._completer.isCompleted) {
      request._completer.complete(approved);
    }
  }

  List<AgentActionApprovalRequest> pendingForSession(String sessionId) =>
      _pending.values
          .where((request) => request.sessionId == sessionId)
          .toList();
}

/// Gate for mutating tool executables.
///
/// Returns `null` when the call may proceed (auto / read-only / background
/// agents without a run mode). In [AgentRunMode.confirm] it blocks on user
/// approval and returns a decline [AgentToolResult] for the model when the
/// user rejects the action, so the conversation continues gracefully.
Future<AgentToolResult?> gateMutatingToolCall({
  required String toolName,
  required String summary,
  Map<String, String> details = const {},
}) async {
  final context = AgentCallToolContext.current;
  final mode = AgentRunMode.fromWire(
    context?.state.metadata[AgentRunMode.metadataKey] as String?,
  );
  if (context == null || mode != AgentRunMode.confirm) return null;

  final approved = await AgentActionApprovalService.instance.requestApproval(
    sessionId: context.state.sessionId,
    toolName: toolName,
    summary: summary,
    details: details,
    cancelToken: context.cancelToken,
  );
  if (approved) return null;

  return AgentToolResult(
    content: TextPart(
      'The user declined the "$toolName" action in ask-first mode. '
      'Do not retry the same call. Briefly acknowledge, then adjust based on '
      'user feedback or continue without this action.',
    ),
  );
}
