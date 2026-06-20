import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/time_context.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

class AgentRunTraceService {
  static final AgentRunTraceService instance = AgentRunTraceService._();

  AgentRunTraceService._({FileSystemService? fileSystem})
      : _fileSystem = fileSystem;

  factory AgentRunTraceService.withFileSystem(FileSystemService fileSystem) {
    return AgentRunTraceService._(fileSystem: fileSystem);
  }

  final FileSystemService? _fileSystem;
  final Logger _logger = getLogger('AgentRunTraceService');

  FileSystemService get _fs => _fileSystem ?? FileSystemService.instance;

  Future<AgentRunTrace> startChatTurn({
    required String userId,
    required String runId,
    required String sessionId,
    required String turnId,
    required String taskId,
    required String agentName,
    required String scene,
    required String? sceneId,
    required String message,
    required int imageCount,
    required List<Map<String, String>>? refs,
    required bool isQuickQuery,
    required String runMode,
    required DateTime userMessageTime,
    DateTime? startedAt,
  }) async {
    try {
      final started = startedAt ?? DateTime.now();
      final safeRunId = _sanitizePathSegment(runId);
      final traceDir = Directory(
        path.join(
          _fs.getSystemPath(userId),
          'AgentRuns',
          _dateFolder(started),
          safeRunId,
        ),
      );
      await traceDir.create(recursive: true);

      final trace = AgentRunTrace._(
        logger: _logger,
        runId: runId,
        traceDirPath: traceDir.path,
      );
      await trace.initializeChatTurn(
        userId: userId,
        sessionId: sessionId,
        turnId: turnId,
        taskId: taskId,
        agentName: agentName,
        scene: scene,
        sceneId: sceneId,
        message: message,
        imageCount: imageCount,
        refs: refs,
        isQuickQuery: isQuickQuery,
        runMode: runMode,
        userMessageTime: userMessageTime,
        startedAt: started,
      );
      return trace;
    } catch (e, st) {
      _logger.warning('Failed to start agent run trace: $e', e, st);
      return AgentRunTrace.noop();
    }
  }

  static String _dateFolder(DateTime dateTime) {
    final local = dateTime.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  static String _sanitizePathSegment(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return 'run';
    if (sanitized.length <= 120) return sanitized;
    return sanitized.substring(0, 120);
  }
}

class AgentRunTrace {
  AgentRunTrace._({
    required Logger logger,
    required this.runId,
    required this.traceDirPath,
  })  : _logger = logger,
        enabled = true,
        jsonlPath = path.join(traceDirPath, 'trace.jsonl'),
        markdownPath = path.join(traceDirPath, 'trace.md');

  AgentRunTrace.noop()
      : _logger = getLogger('AgentRunTraceService'),
        enabled = false,
        runId = '',
        traceDirPath = '',
        jsonlPath = '',
        markdownPath = '';

  static const int maxFieldChars = 20000;

  final Logger _logger;
  final bool enabled;
  final String runId;
  final String traceDirPath;
  final String jsonlPath;
  final String markdownPath;
  final Lock _lock = Lock();

  bool _thoughtSectionStarted = false;

  Future<void> initializeChatTurn({
    required String userId,
    required String sessionId,
    required String turnId,
    required String taskId,
    required String agentName,
    required String scene,
    required String? sceneId,
    required String message,
    required int imageCount,
    required List<Map<String, String>>? refs,
    required bool isQuickQuery,
    required String runMode,
    required DateTime userMessageTime,
    required DateTime startedAt,
  }) async {
    if (!enabled) return;

    final metadata = {
      'run_id': runId,
      'user_id': userId,
      'session_id': sessionId,
      'turn_id': turnId,
      'task_id': taskId,
      'agent_name': agentName,
      'scene': scene,
      if (sceneId != null) 'scene_id': sceneId,
      'is_quick_query': isQuickQuery,
      'run_mode': runMode,
      'image_count': imageCount,
      'user_message_time': userMessageTime.toIso8601String(),
      'user_message_time_local': formatLocalDateTimeWithZone(userMessageTime),
      'started_at': startedAt.toIso8601String(),
      'started_at_local': formatLocalDateTimeWithZone(startedAt),
      if (refs != null && refs.isNotEmpty) 'refs': refs,
    };

    final header = StringBuffer()
      ..writeln('# Agent Run Trace')
      ..writeln()
      ..writeln('- Run ID: `$runId`')
      ..writeln('- Agent: `$agentName`')
      ..writeln('- Session ID: `$sessionId`')
      ..writeln('- Turn ID: `$turnId`')
      ..writeln('- Task ID: `$taskId`')
      ..writeln('- Scene: `$scene${sceneId == null ? '' : ' / $sceneId'}`')
      ..writeln('- Run Mode: `$runMode`')
      ..writeln('- Quick Query: `$isQuickQuery`')
      ..writeln('- Started: ${formatLocalDateTimeWithZone(startedAt)}')
      ..writeln(
          '- User Message Time: ${formatLocalDateTimeWithZone(userMessageTime)}')
      ..writeln('- Attachments: $imageCount image(s)')
      ..writeln()
      ..writeln(
        '> Thought Stream only contains thought/plan chunks surfaced by the provider/runtime. Hidden model reasoning is not available to the app.',
      )
      ..writeln()
      ..writeln('## User Input')
      ..writeln()
      ..writeln(
        message.trim().isEmpty
            ? '_No text input; the turn may contain attachments._'
            : _fenced(message),
      )
      ..writeln();

    if (refs != null && refs.isNotEmpty) {
      header
        ..writeln('## References')
        ..writeln();
      for (final ref in refs) {
        header
          ..writeln('- `${ref['type'] ?? 'unknown'}` ${ref['title'] ?? ''}')
          ..writeln()
          ..writeln(_fenced(_truncate(ref['content'] ?? '', 4000)))
          ..writeln();
      }
    }

    await _lock.synchronized(() async {
      await File(markdownPath).writeAsString(header.toString(), flush: true);
      await File(jsonlPath).writeAsString(
        '${jsonEncode(_eventEnvelope('run_started', metadata))}\n',
        flush: true,
      );
    });
  }

  Future<void> recordModel({
    required String model,
    required String clientType,
  }) {
    return _append(
      type: 'model_selected',
      data: {
        'model': model,
        'client_type': clientType,
      },
      markdown: StringBuffer()
        ..writeln('## Model')
        ..writeln()
        ..writeln('- Model: `$model`')
        ..writeln('- Client: `$clientType`')
        ..writeln(),
    );
  }

  Future<void> recordAgentStarted({
    required String agentName,
    required String agentId,
  }) {
    return _append(
      type: 'agent_started',
      data: {
        'agent_name': agentName,
        'agent_id': agentId,
      },
      markdown: StringBuffer()
        ..writeln('## Agent Started')
        ..writeln()
        ..writeln('- Name: `$agentName`')
        ..writeln('- ID: `$agentId`')
        ..writeln(),
    );
  }

  Future<void> recordPlan(String planText) {
    return _append(
      type: 'plan',
      data: {'text': _truncate(planText, maxFieldChars)},
      markdown: StringBuffer()
        ..writeln('## Plan')
        ..writeln()
        ..writeln(planText.trim().isEmpty ? '_Empty plan._' : planText.trim())
        ..writeln(),
    );
  }

  Future<void> recordThoughtChunk(String text) {
    if (text.isEmpty) return Future.value();
    final markdown = StringBuffer();
    if (!_thoughtSectionStarted) {
      _thoughtSectionStarted = true;
      markdown
        ..writeln('## Thought Stream')
        ..writeln();
    }
    markdown.write(text);
    return _append(
      type: 'thought_chunk',
      data: {'text': _truncate(text, maxFieldChars)},
      markdown: markdown,
    );
  }

  Future<void> recordOutputChunk(String text) {
    if (text.isEmpty) return Future.value();
    return _append(
      type: 'output_chunk',
      data: {'text': _truncate(text, maxFieldChars)},
    );
  }

  Future<void> recordTraceStarted({
    required String id,
    String? parentId,
    required String kind,
    required String name,
    required String args,
    String? label,
  }) {
    final title = kind == 'delegate' ? 'Delegate Started' : 'Tool Started';
    return _append(
      type: '${kind}_started',
      data: {
        'id': id,
        if (parentId != null) 'parent_id': parentId,
        'kind': kind,
        'name': name,
        'args': _truncate(args, maxFieldChars),
        if (label != null) 'label': label,
      },
      markdown: StringBuffer()
        ..writeln()
        ..writeln('## $title: `$name`')
        ..writeln()
        ..writeln('- ID: `$id`')
        ..writeln(ifNotEmpty('- Parent ID: `$parentId`', parentId))
        ..writeln(ifNotEmpty('- Label: `$label`', label))
        ..writeln()
        ..writeln('Arguments:')
        ..writeln()
        ..writeln(_fenced(_truncate(args, maxFieldChars),
            language: _jsonLanguage(args)))
        ..writeln(),
    );
  }

  Future<void> recordTraceCompleted({
    required String id,
    required String result,
    required bool isError,
    String? status,
    Map<String, dynamic>? metadata,
  }) {
    return _append(
      type: 'trace_completed',
      data: {
        'id': id,
        'result': _truncate(result, maxFieldChars),
        'is_error': isError,
        if (status != null) 'status': status,
        if (metadata != null) 'metadata': metadata,
      },
      markdown: StringBuffer()
        ..writeln('### Result for `$id`')
        ..writeln()
        ..writeln('- Status: `${status ?? (isError ? 'error' : 'success')}`')
        ..writeln()
        ..writeln(_fenced(_truncate(result, maxFieldChars)))
        ..writeln(),
    );
  }

  Future<void> recordFinalResponse(
    String response, {
    Map<String, dynamic>? usage,
  }) {
    return _append(
      type: 'final_response',
      data: {
        'response': _truncate(response, maxFieldChars),
        if (usage != null) 'usage': usage,
      },
      markdown: StringBuffer()
        ..writeln()
        ..writeln('## Final Response')
        ..writeln()
        ..writeln(_fenced(_truncate(response, maxFieldChars)))
        ..writeln()
        ..write(_usageMarkdown(usage)),
    );
  }

  Future<void> recordError(String message, {String? details}) {
    return _append(
      type: 'error',
      data: {
        'message': message,
        if (details != null) 'details': _truncate(details, maxFieldChars),
      },
      markdown: StringBuffer()
        ..writeln()
        ..writeln('## Error')
        ..writeln()
        ..writeln('- Message: $message')
        ..writeln()
        ..writeln(ifNotEmpty(
            _fenced(_truncate(details ?? '', maxFieldChars)), details))
        ..writeln(),
    );
  }

  Future<void> recordAgentStopped({String? error}) {
    return _append(
      type: 'agent_stopped',
      data: {
        'ok': error == null,
        if (error != null) 'error': _truncate(error, maxFieldChars),
      },
      markdown: StringBuffer()
        ..writeln()
        ..writeln('## Agent Stopped')
        ..writeln()
        ..writeln(error == null
            ? 'Completed without reported error.'
            : _fenced(error))
        ..writeln(),
    );
  }

  Future<void> _append({
    required String type,
    required Map<String, dynamic> data,
    StringBuffer? markdown,
  }) async {
    if (!enabled) return;
    try {
      await _lock.synchronized(() async {
        await File(jsonlPath).writeAsString(
          '${jsonEncode(_eventEnvelope(type, data))}\n',
          mode: FileMode.append,
        );
        if (markdown != null && markdown.isNotEmpty) {
          await File(markdownPath).writeAsString(
            markdown.toString(),
            mode: FileMode.append,
          );
        }
      });
    } catch (e, st) {
      _logger.warning(
          'Failed to append agent run trace event $type: $e', e, st);
    }
  }

  Map<String, dynamic> _eventEnvelope(
    String type,
    Map<String, dynamic> data,
  ) {
    final now = DateTime.now();
    return {
      'type': type,
      'time': now.toIso8601String(),
      'time_local': formatLocalDateTimeWithZone(now),
      ..._jsonSafeMap(data),
    };
  }

  static Map<String, dynamic> _jsonSafeMap(Map<String, dynamic> map) {
    return {
      for (final entry in map.entries) entry.key: _jsonSafe(entry.value),
    };
  }

  static dynamic _jsonSafe(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafe(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList();
    }
    return value.toString();
  }

  static String ifNotEmpty(String text, Object? value) {
    if (value == null) return '';
    if (value is String && value.isEmpty) return '';
    return text;
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n\n[truncated ${text.length - maxChars} chars]';
  }

  static String _fenced(String text, {String? language}) {
    var longestBacktickRun = 0;
    for (final match in RegExp(r'`+').allMatches(text)) {
      final length = match.group(0)!.length;
      if (length > longestBacktickRun) longestBacktickRun = length;
    }
    final fence = '`' * (longestBacktickRun >= 3 ? longestBacktickRun + 1 : 3);
    final lang = language ?? '';
    return '$fence$lang\n$text\n$fence';
  }

  static String? _jsonLanguage(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return 'json';
    return null;
  }

  static String _usageMarkdown(Map<String, dynamic>? usage) {
    if (usage == null || usage.isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln('Usage:')
      ..writeln()
      ..writeln(_fenced(const JsonEncoder.withIndent('  ').convert(usage),
          language: 'json'))
      ..writeln();
    return buffer.toString();
  }
}
