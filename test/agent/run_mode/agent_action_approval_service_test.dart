import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/run_mode/agent_action_approval_service.dart';
import 'package:memex/agent/run_mode/agent_run_mode.dart';

void main() {
  final service = AgentActionApprovalService.instance;

  group('AgentRunMode', () {
    test('fromWire parses wire names and falls back to auto', () {
      expect(AgentRunMode.fromWire('auto'), AgentRunMode.auto);
      expect(AgentRunMode.fromWire('confirm'), AgentRunMode.confirm);
      expect(AgentRunMode.fromWire('read_only'), AgentRunMode.readOnly);
      expect(AgentRunMode.fromWire('bogus'), AgentRunMode.auto);
      expect(AgentRunMode.fromWire(null), AgentRunMode.auto);
    });
  });

  group('AgentActionApprovalService', () {
    test('auto-denies when no UI is attached to the session', () async {
      final approved = await service.requestApproval(
        sessionId: 'session-unattached',
        toolName: 'submit_record',
        summary: 'content',
      );
      expect(approved, isFalse);
    });

    test('resolves approval when UI approves', () async {
      service.attachSession('session-a');
      addTearDown(() => service.detachSession('session-a'));

      final requests = <AgentActionApprovalRequest>[];
      final sub = service.requests.listen(requests.add);
      addTearDown(sub.cancel);

      final future = service.requestApproval(
        sessionId: 'session-a',
        toolName: 'Write',
        summary: '/PKM/note.md',
      );
      await Future<void>.delayed(Duration.zero);

      expect(requests, hasLength(1));
      expect(service.pendingForSession('session-a'), hasLength(1));

      service.resolve(requests.single.id, approved: true);
      expect(await future, isTrue);
      expect(service.pendingForSession('session-a'), isEmpty);
    });

    test('resolves denial when UI denies', () async {
      service.attachSession('session-b');
      addTearDown(() => service.detachSession('session-b'));

      final requests = <AgentActionApprovalRequest>[];
      final sub = service.requests.listen(requests.add);
      addTearDown(sub.cancel);

      final future = service.requestApproval(
        sessionId: 'session-b',
        toolName: 'Remove',
        summary: '/Cards/x.yaml',
      );
      await Future<void>.delayed(Duration.zero);

      service.resolve(requests.single.id, approved: false);
      expect(await future, isFalse);
    });

    test('detachSession denies everything still pending', () async {
      service.attachSession('session-c');

      final future = service.requestApproval(
        sessionId: 'session-c',
        toolName: 'submit_record',
        summary: 'pending record',
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.pendingForSession('session-c'), hasLength(1));

      service.detachSession('session-c');
      expect(await future, isFalse);
      expect(service.pendingForSession('session-c'), isEmpty);
    });

    test('resolve is idempotent for unknown ids', () {
      expect(
        () => service.resolve('does-not-exist', approved: true),
        returnsNormally,
      );
    });
  });
}
