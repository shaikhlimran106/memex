import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:memex/data/services/app_action_service.dart';
import 'package:memex/utils/logger.dart';

/// Bridges native Android/iOS deep links into [AppActionService].
class AppActionLinkService {
  AppActionLinkService._();

  static final AppActionLinkService instance = AppActionLinkService._();

  static const MethodChannel _methodChannel = MethodChannel(
    'com.memexlab.memex/app_actions',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.memexlab.memex/app_action_events',
  );

  final _logger = getLogger('AppActionLinkService');

  StreamSubscription<String>? _linkSubscription;
  bool _initialized = false;

  Future<void> initialize({AppActionService? actionService}) async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid && !Platform.isIOS) return;

    final actions = actionService ?? AppActionService.instance;
    await _consumeInitialLink(actions);

    _linkSubscription = _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is String && event.isNotEmpty)
        .cast<String>()
        .listen(
      (link) => actions.handleDeepLink(link),
      onError: (Object error, StackTrace stackTrace) {
        _logger.warning('Error in app action link stream: $error');
      },
    );
  }

  Future<void> _consumeInitialLink(AppActionService actions) async {
    try {
      final link = await _methodChannel.invokeMethod<String>('getInitialLink');
      if (link == null || link.isEmpty) return;
      actions.handleDeepLink(link);
      await _methodChannel.invokeMethod<void>('clearInitialLink');
    } on MissingPluginException {
      // Platform bridge is not available in tests or unsupported platforms.
    } catch (error, stackTrace) {
      _logger.warning(
        'Error reading initial app action link: $error',
        error,
        stackTrace,
      );
    }
  }

  @override
  String toString() => 'AppActionLinkService(initialized: $_initialized)';

  Future<void> dispose() async {
    await _linkSubscription?.cancel();
    _linkSubscription = null;
    _initialized = false;
  }
}
