import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/chat_service.dart';

void main() {
  group('isActiveChatTurnTaskForSession', () {
    test('matches only active chat turn tasks for the requested session', () {
      const taskType = 'super_agent_chat_turn_task';

      expect(
        isActiveChatTurnTaskForSession(
          sessionId: 'session-a',
          taskType: taskType,
          expectedTaskType: taskType,
          status: 'pending',
          payloadJson: jsonEncode({'session_id': 'session-a'}),
        ),
        isTrue,
      );

      expect(
        isActiveChatTurnTaskForSession(
          sessionId: 'session-a',
          taskType: taskType,
          expectedTaskType: taskType,
          status: 'pending',
          payloadJson: jsonEncode({'session_id': 'session-b'}),
        ),
        isFalse,
      );

      expect(
        isActiveChatTurnTaskForSession(
          sessionId: 'session-a',
          taskType: taskType,
          expectedTaskType: taskType,
          status: 'completed',
          payloadJson: jsonEncode({'session_id': 'session-a'}),
        ),
        isFalse,
      );

      expect(
        isActiveChatTurnTaskForSession(
          sessionId: 'session-a',
          taskType: 'other_task',
          expectedTaskType: taskType,
          status: 'processing',
          payloadJson: jsonEncode({'session_id': 'session-a'}),
        ),
        isFalse,
      );
    });
  });
}
