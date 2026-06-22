import 'dart:convert';
import 'dart:io';

import 'package:memex/data/services/file_system_service.dart';
import 'package:path/path.dart' as p;

typedef AgentStateContentReader = Future<String> Function();

String? _stringOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return text;
}

class AgentStateDebugEntry {
  const AgentStateDebugEntry({
    required this.path,
    required this.sessionId,
    required this.title,
    required this.subtitle,
    required this.modified,
    required this.readContent,
    this.metadata = const {},
    this.messageCount = 0,
  });

  final String path;
  final String sessionId;
  final String title;
  final String subtitle;
  final DateTime modified;
  final AgentStateContentReader readContent;
  final Map<String, dynamic> metadata;
  final int messageCount;

  bool get isChild => metadata['sub_agent_mode'] == true;
  String? get parentSessionId => _stringOrNull(metadata['parent_session_id']);
  String? get childName => _stringOrNull(metadata['child_name']);
}

class AgentStateDebugService {
  AgentStateDebugService._({FileSystemService? fileSystem})
      : _fileSystem = fileSystem;

  static final AgentStateDebugService instance = AgentStateDebugService._();

  factory AgentStateDebugService.withFileSystem(FileSystemService fileSystem) {
    return AgentStateDebugService._(fileSystem: fileSystem);
  }

  final FileSystemService? _fileSystem;

  FileSystemService get _fs => _fileSystem ?? FileSystemService.instance;

  Future<List<AgentStateDebugEntry>> listStates({
    required String userId,
    String? rootPath,
  }) async {
    final root = Directory(
      rootPath ?? await _fs.getAgentStateDirectory(userId),
    );
    final states = <AgentStateDebugEntry>[];
    if (!await root.exists()) return states;

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      states.add(await _entryFromFile(entity));
    }
    states.sort((a, b) => b.modified.compareTo(a.modified));
    return states;
  }

  String renderStateContent(
    String raw,
    AgentStateDebugEntry entry,
    List<AgentStateDebugEntry> allEntries,
  ) {
    final decoded = _tryDecodeMap(raw);
    if (decoded == null) {
      return '# Agent State\n\nCould not parse state JSON.\n\n${_fenced(raw)}';
    }

    final metadata = _asMap(decoded['metadata']);
    final history = _asMap(decoded['history']);
    final messages = _asList(history['messages']);
    final activeSkills = _asList(decoded['activeSkills']);
    final linkedChildIds = _extractLinkedChildSessionIds(decoded);
    final linkedChildren = _linkedChildrenFor(
      parentSessionId: entry.sessionId,
      linkedChildIds: linkedChildIds,
      allEntries: allEntries,
    );

    final buffer = StringBuffer()
      ..writeln('# Agent State')
      ..writeln()
      ..writeln('## Summary')
      ..writeln()
      ..writeln('- Session ID: `${entry.sessionId}`')
      ..writeln('- File: `${entry.path}`')
      ..writeln('- Modified: ${_formatDateTime(entry.modified)}')
      ..writeln('- Running: `${decoded['isRunning'] == true}`')
      ..writeln('- Total Loops: `${decoded['totalLoopCount'] ?? 0}`')
      ..writeln('- Current Loop: `${decoded['currentLoopCount'] ?? 0}`');

    final lastError = _stringOrNull(decoded['lastError']);
    if (lastError != null) {
      buffer.writeln('- Last Error: ${_inlineCode(lastError)}');
    }
    if (activeSkills.isNotEmpty) {
      buffer.writeln(
        '- Active Skills: ${activeSkills.map(_inlineCode).join(', ')}',
      );
    }
    if (entry.isChild) {
      buffer.writeln('- Child State: `true`');
      buffer.writeln('- Child Name: `${entry.childName ?? 'unknown'}`');
      buffer
          .writeln('- Parent Session: `${entry.parentSessionId ?? 'unknown'}`');
      final delegateRunId = _stringOrNull(metadata['delegate_run_id']);
      if (delegateRunId != null) {
        buffer.writeln('- Delegate Run ID: `$delegateRunId`');
      }
    } else {
      buffer.writeln('- Linked Child States: `${linkedChildren.length}`');
    }
    buffer.writeln();

    if (linkedChildren.isNotEmpty) {
      buffer
        ..writeln('## Linked Child States')
        ..writeln();
      for (final child in linkedChildren) {
        final mode =
            child.fromToolResult ? 'delegate result' : 'parent_session_id';
        buffer.writeln(
          '- `${child.entry.sessionId}` (${child.entry.childName ?? child.entry.title}) via $mode',
        );
      }
      buffer.writeln();
    }

    buffer
      ..writeln('## Metadata')
      ..writeln()
      ..writeln(_fenced(_formatJson(metadata), language: 'json'))
      ..writeln();

    final plan = decoded['plan'];
    if (plan != null) {
      buffer
        ..writeln('## Plan')
        ..writeln()
        ..writeln(_fenced(_formatJson(plan), language: 'json'))
        ..writeln();
    }

    _writeUsageSection(buffer, decoded);

    buffer
      ..writeln('## History')
      ..writeln();
    if (messages.isEmpty) {
      buffer.writeln('_No messages in state history._');
    } else {
      for (var i = 0; i < messages.length; i++) {
        _writeMessage(buffer, i + 1, _asMap(messages[i]));
      }
    }

    return buffer.toString();
  }

  static Future<AgentStateDebugEntry> _entryFromFile(File file) async {
    final stat = await file.stat();
    final content = await file.readAsString();
    final decoded = _tryDecodeMap(content);
    final sessionId = _stringOrNull(decoded?['sessionId']) ??
        p.basenameWithoutExtension(file.path);
    final metadata = _asMap(decoded?['metadata']);
    final messages = _asList(_asMap(decoded?['history'])['messages']);
    final isChild = metadata['sub_agent_mode'] == true;
    final childName = _stringOrNull(metadata['child_name']);
    final parentSessionId = _stringOrNull(metadata['parent_session_id']);
    final scene = _stringOrNull(metadata['scene']);
    final title = isChild ? (childName ?? sessionId) : sessionId;
    final subtitle = isChild
        ? 'child of ${parentSessionId ?? 'unknown'} | ${messages.length} messages'
        : '${scene ?? 'agent'} | ${messages.length} messages';

    return AgentStateDebugEntry(
      path: file.path,
      sessionId: sessionId,
      title: title,
      subtitle: subtitle,
      modified: stat.modified,
      readContent: file.readAsString,
      metadata: metadata,
      messageCount: messages.length,
    );
  }

  static void _writeUsageSection(
    StringBuffer buffer,
    Map<String, dynamic> state,
  ) {
    final usages = _asList(state['usages']);
    final currentLoopUsages = _asList(state['currentLoopUsages']);
    if (usages.isEmpty && currentLoopUsages.isEmpty) return;

    int prompt = 0;
    int completion = 0;
    int cached = 0;
    int total = 0;
    for (final usage in [...usages, ...currentLoopUsages]) {
      final map = _asMap(usage);
      prompt += _intValue(map['promptTokens']);
      completion += _intValue(map['completionTokens']);
      cached += _intValue(map['cachedToken']);
      total += _intValue(map['totalTokens']);
    }

    buffer
      ..writeln('## Usage')
      ..writeln()
      ..writeln(
        '- Calls: `${usages.length}` saved, `${currentLoopUsages.length}` current-loop',
      )
      ..writeln('- Prompt Tokens: `$prompt`')
      ..writeln('- Completion Tokens: `$completion`')
      ..writeln('- Cached Tokens: `$cached`')
      ..writeln('- Total Tokens: `$total`')
      ..writeln();
  }

  static void _writeMessage(
    StringBuffer buffer,
    int index,
    Map<String, dynamic> message,
  ) {
    final role = _stringOrNull(message['role']) ?? 'unknown';
    buffer
      ..writeln('### $index. $role ${_formatTimestamp(message['timestamp'])}')
      ..writeln();

    final metadata = _asMap(message['metadata']);
    if (metadata.isNotEmpty) {
      buffer
        ..writeln('Message metadata:')
        ..writeln()
        ..writeln(_fenced(_formatJson(metadata), language: 'json'))
        ..writeln();
    }

    switch (role) {
      case 'user':
        _writeContentParts(buffer, _asList(message['contents']));
        break;
      case 'assistant':
        _writeAssistantMessage(buffer, message);
        break;
      case 'tool':
        _writeToolMessage(buffer, message);
        break;
      case 'system':
        final content = _stringOrNull(message['content']);
        if (content != null) {
          buffer
            ..writeln(_fenced(_truncate(content, 12000)))
            ..writeln();
        }
        break;
      default:
        buffer
          ..writeln(_fenced(_formatJson(message), language: 'json'))
          ..writeln();
    }
  }

  static void _writeAssistantMessage(
    StringBuffer buffer,
    Map<String, dynamic> message,
  ) {
    final thought = _stringOrNull(message['thought']);
    if (thought != null) {
      buffer
        ..writeln('Thought:')
        ..writeln()
        ..writeln(_fenced(_truncate(thought, 12000)))
        ..writeln();
    }

    final textOutput = _stringOrNull(message['textOutput']);
    if (textOutput != null) {
      buffer
        ..writeln('Text output:')
        ..writeln()
        ..writeln(_fenced(_truncate(textOutput, 12000)))
        ..writeln();
    }

    final functionCalls = _asList(message['functionCalls']);
    if (functionCalls.isNotEmpty) {
      buffer
        ..writeln('Function calls:')
        ..writeln();
      for (final rawCall in functionCalls) {
        final call = _asMap(rawCall);
        final name = _stringOrNull(call['name']) ?? 'unknown';
        final id = _stringOrNull(call['id']) ?? 'unknown';
        final args = _stringOrNull(call['arguments']) ?? '';
        buffer
          ..writeln('- `$name` id `$id`')
          ..writeln()
          ..writeln(
            _fenced(_formatMaybeJson(args), language: _jsonLanguage(args)),
          )
          ..writeln();
      }
    }

    final usage = message['usage'];
    if (usage != null) {
      buffer
        ..writeln('Usage:')
        ..writeln()
        ..writeln(_fenced(_formatJson(usage), language: 'json'))
        ..writeln();
    }
  }

  static void _writeToolMessage(
    StringBuffer buffer,
    Map<String, dynamic> message,
  ) {
    final results = _asList(message['results']);
    if (results.isEmpty) {
      buffer.writeln('_No tool results._\n');
      return;
    }

    for (final rawResult in results) {
      final result = _asMap(rawResult);
      final name = _stringOrNull(result['name']) ?? 'unknown';
      final id = _stringOrNull(result['id']) ?? 'unknown';
      buffer
        ..writeln('- `$name` id `$id` error `${result['isError'] == true}`')
        ..writeln();

      final args = _stringOrNull(result['arguments']);
      if (args != null && args.isNotEmpty) {
        buffer
          ..writeln('Arguments:')
          ..writeln()
          ..writeln(
            _fenced(_formatMaybeJson(args), language: _jsonLanguage(args)),
          )
          ..writeln();
      }

      final metadata = _asMap(result['metadata']);
      final childSessionId = _childSessionIdFromResultMetadata(metadata);
      if (childSessionId != null) {
        buffer
          ..writeln('Linked child state: `$childSessionId`')
          ..writeln();
      }
      if (metadata.isNotEmpty) {
        buffer
          ..writeln('Result metadata:')
          ..writeln()
          ..writeln(_fenced(_formatJson(metadata), language: 'json'))
          ..writeln();
      }

      _writeContentParts(buffer, _asList(result['content']));
    }
  }

  static void _writeContentParts(StringBuffer buffer, List<dynamic> parts) {
    if (parts.isEmpty) {
      buffer.writeln('_No content parts._\n');
      return;
    }

    for (var i = 0; i < parts.length; i++) {
      final part = _asMap(parts[i]);
      final type = _stringOrNull(part['type']) ?? 'unknown';
      buffer.writeln('Content part ${i + 1}: `$type`');
      switch (type) {
        case 'text':
          buffer
            ..writeln()
            ..writeln(
              _fenced(_truncate(_stringOrNull(part['text']) ?? '', 12000)),
            )
            ..writeln();
          break;
        case 'image':
        case 'audio':
        case 'video':
        case 'document':
          final base64 = _stringOrNull(part['base64Data']);
          final mimeType = _stringOrNull(part['mimeType']);
          buffer
            ..writeln('- MIME: `${mimeType ?? 'unknown'}`')
            ..writeln('- Base64 bytes: `${base64?.length ?? 0}`')
            ..writeln();
          break;
        default:
          buffer
            ..writeln()
            ..writeln(_fenced(_formatJson(part), language: 'json'))
            ..writeln();
      }
    }
  }

  static Set<String> _extractLinkedChildSessionIds(Map<String, dynamic> state) {
    final ids = <String>{};
    final messages = _asList(_asMap(state['history'])['messages']);
    for (final rawMessage in messages) {
      final message = _asMap(rawMessage);
      if (message['role'] != 'tool') continue;
      for (final rawResult in _asList(message['results'])) {
        final result = _asMap(rawResult);
        final childSessionId = _childSessionIdFromResultMetadata(
          _asMap(result['metadata']),
        );
        if (childSessionId != null) {
          ids.add(childSessionId);
        }
      }
    }
    return ids;
  }

  static List<_LinkedChildState> _linkedChildrenFor({
    required String parentSessionId,
    required Set<String> linkedChildIds,
    required List<AgentStateDebugEntry> allEntries,
  }) {
    final bySessionId = {
      for (final entry in allEntries) entry.sessionId: entry,
    };
    final linked = <_LinkedChildState>[];
    final seen = <String>{};

    for (final id in linkedChildIds) {
      final entry = bySessionId[id];
      if (entry == null) continue;
      linked.add(_LinkedChildState(entry, fromToolResult: true));
      seen.add(entry.sessionId);
    }

    for (final entry in allEntries) {
      if (entry.parentSessionId != parentSessionId) continue;
      if (!seen.add(entry.sessionId)) continue;
      linked.add(_LinkedChildState(entry, fromToolResult: false));
    }

    return linked;
  }

  static String? _childSessionIdFromResultMetadata(
    Map<String, dynamic> metadata,
  ) {
    final childResult = metadata['child_result'];
    if (childResult is Map) {
      return _stringOrNull(childResult['child_session_id']);
    }
    return null;
  }

  static Map<String, dynamic>? _tryDecodeMap(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  static List<dynamic> _asList(Object? value) {
    if (value is List) return value;
    return const [];
  }

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _formatJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  static String _formatMaybeJson(String value) {
    try {
      final decoded = jsonDecode(value);
      return _formatJson(decoded);
    } catch (_) {
      return _truncate(value, 12000);
    }
  }

  static String? _jsonLanguage(String value) {
    final trimmed = value.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return 'json';
    return null;
  }

  static String _formatDateTime(DateTime value) {
    return value.toLocal().toIso8601String();
  }

  static String _formatTimestamp(Object? value) {
    final intValue = _intValue(value);
    if (intValue <= 0) return '';
    try {
      final date = intValue > 1000000000000000
          ? DateTime.fromMicrosecondsSinceEpoch(intValue)
          : DateTime.fromMillisecondsSinceEpoch(intValue);
      return '@ ${_formatDateTime(date)}';
    } catch (_) {
      return '@ $value';
    }
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n\n[truncated ${text.length - maxChars} chars]';
  }

  static String _inlineCode(Object? value) {
    final text = value?.toString() ?? '';
    return '`${text.replaceAll('`', '\\`')}`';
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
}

class _LinkedChildState {
  const _LinkedChildState(this.entry, {required this.fromToolResult});

  final AgentStateDebugEntry entry;
  final bool fromToolResult;
}
