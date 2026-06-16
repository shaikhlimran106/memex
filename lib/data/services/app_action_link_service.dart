import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:memex/data/services/app_action_service.dart';
import 'package:memex/utils/logger.dart';

typedef AppActionPlatformSupport = bool Function();
typedef InitialAppActionLinkReader = Future<String?> Function();
typedef InitialAppActionLinkClearer = Future<void> Function();
typedef AppActionEventStreamFactory = Stream<dynamic> Function();

/// Bridges native Android/iOS deep links into [AppActionService].
class AppActionLinkService {
  AppActionLinkService._({
    AppActionPlatformSupport? isSupportedPlatform,
    InitialAppActionLinkReader? readInitialLink,
    InitialAppActionLinkClearer? clearInitialLink,
    AppActionEventStreamFactory? eventStream,
  })  : _isSupportedPlatform =
            isSupportedPlatform ?? (() => Platform.isAndroid || Platform.isIOS),
        _readInitialLink = readInitialLink ??
            (() => _methodChannel.invokeMethod<String>('getInitialLink')),
        _clearInitialLink = clearInitialLink ??
            (() => _methodChannel.invokeMethod<void>('clearInitialLink')),
        _eventStream =
            eventStream ?? (() => _eventChannel.receiveBroadcastStream());

  static final AppActionLinkService instance = AppActionLinkService._();

  static const MethodChannel _methodChannel = MethodChannel(
    'com.memexlab.memex/app_actions',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.memexlab.memex/app_action_events',
  );

  @visibleForTesting
  factory AppActionLinkService.forTesting({
    AppActionPlatformSupport? isSupportedPlatform,
    InitialAppActionLinkReader? readInitialLink,
    InitialAppActionLinkClearer? clearInitialLink,
    AppActionEventStreamFactory? eventStream,
  }) {
    return AppActionLinkService._(
      isSupportedPlatform: isSupportedPlatform,
      readInitialLink: readInitialLink,
      clearInitialLink: clearInitialLink,
      eventStream: eventStream,
    );
  }

  final _logger = getLogger('AppActionLinkService');
  final AppActionPlatformSupport _isSupportedPlatform;
  final InitialAppActionLinkReader _readInitialLink;
  final InitialAppActionLinkClearer _clearInitialLink;
  final AppActionEventStreamFactory _eventStream;

  StreamSubscription<String>? _linkSubscription;
  bool _initialized = false;

  Future<void> initialize({AppActionService? actionService}) async {
    if (_initialized) return;
    _initialized = true;

    if (!_isSupportedPlatform()) return;

    final actions = actionService ?? AppActionService.instance;
    await _consumeInitialLink(actions);

    _linkSubscription = _eventStream()
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
      final link = await _readInitialLink();
      if (link == null || link.isEmpty) return;
      actions.handleDeepLink(link);
      await _clearInitialLink();
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
