import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_run_trace_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AgentRunTraceService', () {
    late Directory tempDir;
    late AgentRunTraceService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'memex_agent_run_trace_test_',
      );
      service = AgentRunTraceService.withFileSystem(
        FileSystemService.detached(dataRoot: tempDir.path),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writes readable markdown and machine-readable jsonl', () async {
      final trace = await service.startChatTurn(
        userId: 'user-1',
        runId: 'task:001/abc',
        sessionId: 'session-1',
        turnId: 'turn-1',
        taskId: 'task-1',
        agentName: 'memex_agent',
        scene: 'super_agent_home',
        sceneId: null,
        message: 'hello ``` code',
        imageCount: 1,
        refs: [
          {
            'type': 'card',
            'title': 'Daily note',
            'content': 'Referenced card content',
          },
        ],
        isQuickQuery: false,
        runMode: 'auto',
        userMessageTime: DateTime(2026, 6, 20, 10, 29),
        startedAt: DateTime(2026, 6, 20, 10, 30),
      );

      await trace.recordModel(model: 'gpt-test', clientType: 'FakeClient');
      await trace.recordAgentStarted(
        agentName: 'memex_agent',
        agentId: 'agent-1',
      );
      await trace.recordPlan('- Inspect memory\n- Call tools');
      await trace.recordThoughtChunk('I should inspect memory first. ');
      await trace.recordTraceStarted(
        id: 'call-1',
        kind: 'tool',
        name: 'Read',
        args: '{"path":"/PKM/a.md"}',
      );
      await trace.recordTraceCompleted(
        id: 'call-1',
        result: 'tool result text',
        isError: false,
        metadata: {'artifact': 'none'},
      );
      await trace.recordFinalResponse(
        'final answer',
        usage: {'total_tokens': 42},
      );
      await trace.recordAgentStopped();

      final traceDir = Directory(
        p.join(
          tempDir.path,
          'workspace',
          '_user-1',
          '_System',
          'AgentRuns',
          '2026-06-20',
          'task_001_abc',
        ),
      );
      final markdownFile = File(p.join(traceDir.path, 'trace.md'));
      final jsonlFile = File(p.join(traceDir.path, 'trace.jsonl'));

      expect(await markdownFile.exists(), isTrue);
      expect(await jsonlFile.exists(), isTrue);

      final markdown = await markdownFile.readAsString();
      expect(markdown, contains('# Agent Run Trace'));
      expect(markdown, contains('````\nhello ``` code\n````'));
      expect(markdown, contains('## Plan'));
      expect(markdown, contains('## Thought Stream'));
      expect(markdown, contains('I should inspect memory first.'));
      expect(markdown, contains('## Tool Started: `Read`'));
      expect(markdown, contains('tool result text'));
      expect(markdown, contains('## Final Response'));
      expect(markdown, contains('final answer'));

      final events = (await jsonlFile.readAsLines())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(
        events.map((event) => event['type']),
        containsAllInOrder([
          'run_started',
          'model_selected',
          'agent_started',
          'plan',
          'thought_chunk',
          'tool_started',
          'trace_completed',
          'final_response',
          'agent_stopped',
        ]),
      );
      expect(events.first['run_id'], 'task:001/abc');
      expect(events.first['user_message_time_local'], contains('+'));
      expect(events.first['refs'], isA<List<dynamic>>());
    });
  });
}
