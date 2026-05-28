import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'graders.dart';

void main() {
  group('PKM eval graders', () {
    test('routes from workspace diff, not outcome trajectory fields', () async {
      final grader = PkmRoutedCorrectlyGrader(
        expectedBuckets: const ['Areas/Health/'],
        expectedFiles: const ['Areas/Health/Sleep.md'],
      );

      final score = await grader.grade(
        trial: _trial(),
        transcript: _emptyTranscript(),
        outcome: const Outcome(
          environmentState: {'skipped_pkm': false},
          workspaceDiff: WorkspaceDiff(
            modified: ['Areas/Health/Sleep.md'],
          ),
        ),
        context: _context(),
      );

      expect(score.value, 1.0);
      expect(score.passed, isTrue);
    });

    test('read-before-write uses transcript tool-call order', () async {
      final grader = PkmReadBeforeWriteGrader(
        requiredReadPath: 'Areas/Health/Sleep.md',
      );

      final pass = await grader.grade(
        trial: _trial(),
        transcript: _transcript([
          _toolCall('Read', {'file_path': 'Areas/Health/Sleep.md'}),
          _toolCall('Edit', {'file_path': 'Areas/Health/Sleep.md'}),
        ]),
        outcome: const Outcome(environmentState: {}),
        context: _context(),
      );
      expect(pass.value, 1.0);

      final fail = await grader.grade(
        trial: _trial(),
        transcript: _transcript([
          _toolCall('Edit', {'file_path': 'Areas/Health/Sleep.md'}),
          _toolCall('Read', {'file_path': 'Areas/Health/Sleep.md'}),
        ]),
        outcome: const Outcome(environmentState: {}),
        context: _context(),
      );
      expect(fail.value, 0.0);
    });
  });
}

Transcript _emptyTranscript() => _transcript(const []);

Transcript _transcript(List<ToolCallRecord> toolCalls) => Transcript(
      messages: const [],
      toolCalls: toolCalls,
      metrics: TranscriptMetrics(
        nTurns: 0,
        nToolCalls: toolCalls.length,
        nTotalTokens: 0,
      ),
    );

ToolCallRecord _toolCall(String toolName, Map<String, dynamic> arguments) {
  final at = DateTime(2026, 5, 26);
  return ToolCallRecord(
    callId: '$toolName-1',
    toolName: toolName,
    arguments: arguments,
    startedAt: at,
    endedAt: at,
  );
}

Trial _trial() {
  final at = DateTime(2026, 5, 26);
  return Trial(
    runName: 'test',
    suiteName: 'pkm',
    taskId: 'task',
    trialIndex: 0,
    startedAt: at,
    endedAt: at,
    status: TrialStatus.passed,
  );
}

EvalContext _context() => EvalContext(
      workspaceDir: Directory.systemTemp,
      clock: FixedEvalClock(DateTime(2026, 5, 26)),
      llmClient: _NoopLLMClient(),
      controller: AgentController(),
    );

class _NoopLLMClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }
}
