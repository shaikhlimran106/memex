import 'dart:async';
import 'package:logging/logging.dart';
import 'package:drift/drift.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:memex/db/app_database.dart';

/// Type of the agent activity message
enum AgentActivityType {
  agent_start,
  agent_stop,
  tool_call_reqeust,
  tool_call_response,
  thought,
  info,
  error,
  warn,
  plan,
  thought_chunk,
  output_chunk
}

/// Model for UI consumption
class AgentActivityMessageModel {
  final int id;
  final AgentActivityType type;
  final String title;
  final String? content;
  final String? icon;
  final String agentName;
  final String agentId;
  final String? scene;
  final String? sceneId;
  final String? userId;
  final DateTime timestamp;

  AgentActivityMessageModel({
    required this.id,
    required this.type,
    required this.title,
    this.content,
    this.icon,
    required this.agentName,
    required this.agentId,
    this.scene,
    this.sceneId,
    this.userId,
    required this.timestamp,
  });

  factory AgentActivityMessageModel.fromDb(AgentActivityMessage row) {
    return AgentActivityMessageModel(
      id: row.id,
      type: AgentActivityType.values.firstWhere(
        (e) => e.name == row.type,
        orElse: () => AgentActivityType.info,
      ),
      title: row.title,
      content: row.content,
      icon: row.icon,
      agentName: row.agentName,
      agentId: row.agentId ?? '',
      scene: row.scene,
      sceneId: row.sceneId,
      userId: row.userId,
      timestamp: row.timestamp,
    );
  }
}

/// Abstract AgentActivityService interface
abstract class AgentActivityService {
  static AgentActivityService? _instance;
  static AgentActivityService get instance {
    if (_instance == null) {
      throw Exception(
          'AgentActivityService not initialized. Use MemexRouter to initialize it.');
    }
    return _instance!;
  }

  static void setInstance(AgentActivityService service) {
    _instance = service;
  }

  Stream<AgentActivityMessageModel> get messageStream;

  Future<void> pushMessage({
    required AgentActivityType type,
    required String title,
    String? content,
    String? icon,
    required String agentName,
    required String agentId,
    String? scene,
    String? sceneId,
    String? userId,
  });

  Future<List<AgentActivityMessageModel>> getHistory({int limit = 10});
}

class LocalAgentActivityService implements AgentActivityService {
  // Singleton for Local implementation itself if needed, or just use as instance
  static final LocalAgentActivityService _instance =
      LocalAgentActivityService._internal();
  static LocalAgentActivityService get instance => _instance;

  final Logger _logger = Logger('LocalAgentActivityService');
  final _messageController =
      StreamController<AgentActivityMessageModel>.broadcast();
  static const int _databaseMaxAttempts = 4;
  static const Duration _databaseRetryDelay = Duration(milliseconds: 120);

  @override
  Stream<AgentActivityMessageModel> get messageStream =>
      _messageController.stream;

  LocalAgentActivityService._internal();

  final Map<String, StringBuffer> _thoughtBuffers = {};
  final Map<String, StringBuffer> _outputBuffers = {};
  final Map<String, AgentActivityType> _lastChunkTypes = {};

  @override
  Future<void> pushMessage({
    required AgentActivityType type,
    required String title,
    String? content,
    String? icon,
    required String agentName,
    required String agentId,
    String? scene,
    String? sceneId,
    String? userId,
  }) async {
    try {
      final now = DateTime.now();
      String? finalContent = content;

      // Handle streaming chunks
      if (type == AgentActivityType.thought_chunk ||
          type == AgentActivityType.output_chunk) {
        final lastType = _lastChunkTypes[agentId];
        if (lastType != type) {
          if (type == AgentActivityType.thought_chunk) {
            _thoughtBuffers[agentId] = StringBuffer();
          }
          if (type == AgentActivityType.output_chunk) {
            _outputBuffers[agentId] = StringBuffer();
          }
        }
        _lastChunkTypes[agentId] = type;

        if (content != null) {
          if (type == AgentActivityType.thought_chunk) {
            _thoughtBuffers[agentId]?.write(content);
            finalContent = _thoughtBuffers[agentId]?.toString();
          } else {
            _outputBuffers[agentId]?.write(content);
            finalContent = _outputBuffers[agentId]?.toString();
          }
        }
      } else {
        _lastChunkTypes.remove(agentId);
        _thoughtBuffers.remove(agentId);
        _outputBuffers.remove(agentId);
      }

      // 1. Insert into DB (SKIP for chunks)
      int id = -1;
      if (type != AgentActivityType.thought_chunk &&
          type != AgentActivityType.output_chunk) {
        try {
          id = await _insertMessageWithRetry(
            type: type,
            title: title,
            content: finalContent,
            icon: icon,
            agentName: agentName,
            agentId: agentId,
            scene: scene,
            sceneId: sceneId,
            userId: userId,
            timestamp: now,
          );
        } catch (e) {
          if (e.toString().contains("Database not initialized")) {
            // silent ignore
          } else {
            _logger.warning('Failed to persist agent activity: $e');
          }
        }
      }

      // 2. Create model and broadcast
      final message = AgentActivityMessageModel(
        id: id,
        type: type,
        title: title,
        content: finalContent,
        icon: icon,
        agentName: agentName,
        agentId: agentId,
        scene: scene,
        sceneId: sceneId,
        userId: userId,
        timestamp: now,
      );

      _messageController.add(message);
      if (type != AgentActivityType.thought_chunk &&
          type != AgentActivityType.output_chunk) {
        _logger.info(
            'Pushed agent activity: [$type] $title (Agent: $agentName, ID: $agentId)');
      }
    } catch (e, stackTrace) {
      _logger.severe('Failed to push agent activity message', e, stackTrace);
    }
  }

  Future<int> _insertMessageWithRetry({
    required AgentActivityType type,
    required String title,
    required String? content,
    required String? icon,
    required String agentName,
    required String agentId,
    required String? scene,
    required String? sceneId,
    required String? userId,
    required DateTime timestamp,
  }) async {
    for (var attempt = 1; attempt <= _databaseMaxAttempts; attempt++) {
      try {
        final db = AppDatabase.instance;
        return await db.into(db.agentActivityMessages).insert(
              AgentActivityMessagesCompanion.insert(
                type: type.name,
                title: title,
                content: Value(content),
                icon: Value(icon),
                agentName: Value(agentName),
                agentId: Value(agentId),
                scene: Value(scene),
                sceneId: Value(sceneId),
                userId: Value(userId),
                timestamp: timestamp,
              ),
            );
      } catch (error) {
        if (!_isDatabaseLocked(error) || attempt == _databaseMaxAttempts) {
          rethrow;
        }
        _logger.info(
          'Agent activity database locked while persisting message '
          '(attempt $attempt/$_databaseMaxAttempts); retrying.',
        );
        await Future.delayed(
          Duration(milliseconds: _databaseRetryDelay.inMilliseconds * attempt),
        );
      }
    }
    return -1;
  }

  bool _isDatabaseLocked(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('sqliteexception(5)') ||
        message.contains('database_busy');
  }

  @override
  Future<List<AgentActivityMessageModel>> getHistory({int limit = 10}) async {
    try {
      AppDatabase db;
      try {
        db = AppDatabase.instance;
      } catch (e) {
        return [];
      }

      final userId = await UserStorage.getUserId();
      if (userId == null) {
        return [];
      }

      final query = db.select(db.agentActivityMessages)
        ..where((t) => t.userId.equals(userId))
        ..orderBy([
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
        ])
        ..limit(limit);

      final rows = await query.get();
      return rows.map((row) => AgentActivityMessageModel.fromDb(row)).toList();
    } catch (e, stackTrace) {
      _logger.severe('Failed to get history messages: $e', e, stackTrace);
      return [];
    }
  }
}
