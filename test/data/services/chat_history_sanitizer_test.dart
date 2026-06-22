import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/chat_history_sanitizer.dart';

void main() {
  group('ChatHistorySanitizer.stripLegacyReminderTurns', () {
    test('removes reminder + mock "Understood" pairs, keeps real turns', () {
      final state = AgentState.empty();
      state.history.messages.addAll([
        UserMessage([TextPart('记一下今天的事')]),
        UserMessage.text(
            '<system-reminder>\nscene context...\n</system-reminder>'),
        ModelMessage(
          model: 'mocked',
          textOutput: 'Understood, I will keep this context in mind.',
        ),
        ModelMessage(model: 'gemini-3.1-pro', textOutput: '好的,已记录'),
      ]);

      final removed = ChatHistorySanitizer.stripLegacyReminderTurns(state);

      expect(removed, 2);
      final msgs = state.history.messages;
      expect(msgs.length, 2);
      expect(msgs[0], isA<UserMessage>());
      expect((msgs[1] as ModelMessage).model, 'gemini-3.1-pro');
    });

    test('keeps a real assistant message that merely says Understood', () {
      final state = AgentState.empty();
      state.history.messages.addAll([
        UserMessage([TextPart('ok?')]),
        // Real model output (not model=="mocked") must survive even if the
        // text resembles the mock string.
        ModelMessage(
          model: 'gemini-3.1-pro',
          textOutput: 'Understood, I will keep this context in mind.',
        ),
      ]);

      final removed = ChatHistorySanitizer.stripLegacyReminderTurns(state);
      expect(removed, 0);
      expect(state.history.messages.length, 2);
    });

    test('drops mock assistant even if not preceded by a reminder', () {
      final state = AgentState.empty();
      state.history.messages.addAll([
        UserMessage([TextPart('real user turn, not a reminder')]),
        ModelMessage(model: 'mocked', textOutput: 'Understood, ...'),
      ]);

      final removed = ChatHistorySanitizer.stripLegacyReminderTurns(state);
      // Only the mock assistant is dropped; the real user turn is preserved.
      expect(removed, 1);
      expect(state.history.messages.length, 1);
      expect(state.history.messages.single, isA<UserMessage>());
    });

    test('is idempotent', () {
      final state = AgentState.empty();
      state.history.messages.addAll([
        UserMessage.text('<system-reminder>\nx\n</system-reminder>'),
        ModelMessage(model: 'mocked', textOutput: 'Understood'),
        UserMessage([TextPart('hi')]),
      ]);

      ChatHistorySanitizer.stripLegacyReminderTurns(state);
      final removedSecond =
          ChatHistorySanitizer.stripLegacyReminderTurns(state);
      expect(removedSecond, 0);
      expect(state.history.messages.length, 1);
    });
  });
}
