import 'dart:async';
import 'package:logging/logging.dart';
import 'package:memex/domain/models/event_bus_message.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/data/repositories/event_handlers/check_processing_cards_handler.dart';

export 'package:memex/domain/models/event_bus_message.dart';

/// Event bus message handler callback type
typedef EventBusMessageHandler = void Function(EventBusMessage message);

/// In-app event bus: message dispatch for MemexRouter to notify UI, handle check_processing_cards, etc.
class EventBusService {
  static EventBusService? _instance;
  static EventBusService get instance {
    _instance ??= EventBusService._();
    return _instance!;
  }

  EventBusService._() {
    _msgSub = _messageController.stream.listen(_dispatchMessage);
  }

  final Logger _logger = getLogger('EventBusService');

  final _messageController = StreamController<EventBusMessage>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  final Map<EventBusMessageType, List<EventBusMessageHandler>> _handlers = {};

  StreamSubscription? _msgSub;

  bool get isConnected => _isConnected;
  bool _isConnected = false;

  Stream<bool> get connectionState => _connectionStateController.stream;

  /// Connect (called from main when app is ready)
  Future<void> connect() async {
    if (_isConnected) return;
    _isConnected = true;
    _connectionStateController.add(true);
    _logger.info('Event bus connected');
  }

  /// Disconnect
  Future<void> disconnect() async {
    _isConnected = false;
    _connectionStateController.add(false);
    _logger.info('Event bus disconnected');
  }

  /// Send message; route by type to handler (e.g. check_processing_cards)
  void sendMessage(Map<String, dynamic> message) {
    if (!_isConnected) {
      _logger.warning('Cannot process message, not connected');
      return;
    }

    final messageType = message['type'] as String?;
    _logger.info('Received message: $messageType');

    switch (messageType) {
      case 'check_processing_cards':
        handleCheckProcessingCards(message, emitEvent: emitEvent);
        break;
      default:
        _logger.fine('Unknown message type: $messageType');
    }
  }

  /// Emit event (e.g. from MemexRouter) to notify UI
  void emitEvent(EventBusMessage message) {
    if (_isConnected) {
      _messageController.add(message);
    }
  }

  void addHandler(EventBusMessageType type, EventBusMessageHandler handler) {
    _handlers.putIfAbsent(type, () => []).add(handler);
  }

  void removeHandler(EventBusMessageType type, EventBusMessageHandler handler) {
    _handlers[type]?.remove(handler);
  }

  void clearHandlers() {
    _handlers.clear();
  }

  void _dispatchMessage(EventBusMessage message) {
    final handlers = _handlers[message.type] ?? [];
    for (final handler in handlers) {
      try {
        handler(message);
      } catch (e) {
        _logger.severe('Error in message handler: $e');
      }
    }
  }

  void dispose() {
    _msgSub?.cancel();
    _messageController.close();
    _connectionStateController.close();
    _handlers.clear();
  }
}
