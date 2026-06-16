import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:memex/utils/logger.dart';

/// Dispatches app-level actions from platform entry points.
///
/// The same action queue is used by app-icon quick actions and external deep
/// links so the UI can consume a single stable action after normal app
/// readiness checks have completed.
class AppActionService {
  AppActionService._({DateTime Function()? now}) : _now = now ?? DateTime.now;

  @visibleForTesting
  AppActionService.test({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static final AppActionService instance = AppActionService._();

  static const String quickNoteAction = 'quick_note';
  static const Duration defaultLateActionTimeout = Duration(seconds: 2);
  static const Duration _dedupWindow = Duration(seconds: 2);

  static const Set<String> _knownActions = {quickNoteAction};

  final Logger _logger = getLogger('AppActionService');
  final DateTime Function() _now;
  final StreamController<String> _actionController =
      StreamController<String>.broadcast();

  String? _pendingAction;
  String? _consumedAction;
  DateTime? _consumedAt;
  Completer<void>? _actionReady;
  bool _hasListener = false;

  Stream<String> get actionStream => _actionController.stream;

  bool get hasPendingAction => _pendingAction != null;

  /// Called when a platform integration has a raw app action ID.
  void handleAction(String actionType, {String source = 'app_action'}) {
    final action = normalizeActionId(actionType);
    if (action == null) {
      _logger.info('Ignoring unsupported app action from $source: $actionType');
      return;
    }

    if (_isDuplicate(action)) {
      _logger.info('Ignoring duplicate app action from $source: $action');
      return;
    }

    if (_pendingAction == action) {
      _logger.info('Ignoring already pending app action from $source: $action');
      return;
    }

    _logger.info('App action received from $source: $action');
    _pendingAction = action;
    _actionController.add(action);
    if (_hasListener && _actionReady?.isCompleted == false) {
      _actionReady?.complete();
    }
  }

  /// Converts a supported deep link into an app action.
  bool handleDeepLink(String rawLink) {
    final action = actionFromDeepLink(rawLink);
    if (action == null) {
      _logger.info('Ignoring unsupported app deep link: $rawLink');
      return false;
    }
    handleAction(action, source: 'deep_link');
    return true;
  }

  String? normalizeActionId(String actionType) {
    final normalized = actionType.trim();
    if (!_knownActions.contains(normalized)) return null;
    return normalized;
  }

  String? actionFromDeepLink(String rawLink) {
    final trimmed = rawLink.trim();
    if (trimmed.isEmpty) return null;

    Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      return null;
    }

    if (uri.scheme.toLowerCase() != 'memex') return null;

    final host = uri.host.toLowerCase();
    final pathSegments =
        uri.pathSegments.map((segment) => segment.toLowerCase()).toList();

    if (host == quickNoteAction && pathSegments.isEmpty) {
      return quickNoteAction;
    }

    if (host.isEmpty &&
        pathSegments.length == 1 &&
        pathSegments.first == quickNoteAction) {
      return quickNoteAction;
    }

    return null;
  }

  /// Register that a UI listener is ready to handle actions.
  void attach() {
    _hasListener = true;
    if (_pendingAction != null && _actionReady?.isCompleted == false) {
      _actionReady?.complete();
    }
  }

  /// Detach when the UI listener is disposed.
  void detach() {
    _hasListener = false;
    if (_actionReady?.isCompleted == false) {
      _actionReady?.complete();
    }
    _actionReady = null;
  }

  /// Consume the pending action synchronously without waiting.
  String? consumeIfPending() => _consumePending();

  /// Wait briefly for a late platform callback, then consume the pending action.
  Future<String?> consumePendingAction({
    Duration timeout = defaultLateActionTimeout,
  }) async {
    if (_pendingAction != null) {
      return _consumePending();
    }

    _actionReady = Completer<void>();
    try {
      await _actionReady!.future.timeout(timeout);
    } on TimeoutException {
      // No action arrived within the window.
    } finally {
      _actionReady = null;
    }

    return _consumePending();
  }

  /// Reset dedup tracking so a fresh external trigger can deliver the same
  /// action after the app backgrounds or after the UI explicitly allows it.
  void resetConsumed() {
    _consumedAction = null;
    _consumedAt = null;
  }

  @visibleForTesting
  void dispose() {
    detach();
    _actionController.close();
  }

  String? _consumePending() {
    final action = _pendingAction;
    _pendingAction = null;
    if (action != null) {
      _consumedAction = action;
      _consumedAt = _now();
    }
    return action;
  }

  bool _isDuplicate(String action) {
    if (_consumedAction != action || _consumedAt == null) return false;
    return _now().difference(_consumedAt!) < _dedupWindow;
  }
}
