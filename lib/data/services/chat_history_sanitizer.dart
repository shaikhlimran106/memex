import 'package:dart_agent_core/dart_agent_core.dart';

/// One-time cleanup for chat sessions created before scene/location/attachment
/// reminders moved to the transient `systemReminders` channel.
///
/// The old code injected each reminder as a persisted pair: a
/// `<system-reminder>` UserMessage followed by a fake assistant turn
/// `ModelMessage(model: "mocked", textOutput: "Understood, I will keep this
/// context in mind.")`. Over a long session with retries those fake turns
/// dominated the recent history and made the loop detector's LLM diagnosis
/// conclude the model was stuck repeating "Understood" — killing otherwise
/// healthy runs (including ones that had just called the right tool).
///
/// New sessions never create these pairs. This strips the legacy ones from
/// existing history so poisoned sessions recover.
class ChatHistorySanitizer {
  static const String mockModelTag = 'mocked';

  /// Removes legacy reminder/"Understood" turn pairs from [state] history.
  /// Returns the number of messages removed. Idempotent.
  static int stripLegacyReminderTurns(AgentState state) {
    final messages = state.history.messages;
    final kept = <LLMMessage>[];
    var removed = 0;

    for (final message in messages) {
      if (_isMockAssistant(message)) {
        // Drop the paired reminder UserMessage we just kept, if present.
        if (kept.isNotEmpty && _isReminderUserMessage(kept.last)) {
          kept.removeLast();
          removed++;
        }
        removed++; // drop the mock assistant itself
        continue;
      }
      kept.add(message);
    }

    if (removed > 0) {
      state.history.messages = kept;
    }
    return removed;
  }

  static bool _isMockAssistant(LLMMessage message) {
    return message is ModelMessage && message.model == mockModelTag;
  }

  static bool _isReminderUserMessage(LLMMessage message) {
    if (message is! UserMessage) return false;
    if (message.contents.length != 1) return false;
    final part = message.contents.first;
    return part is TextPart &&
        part.text.trimLeft().startsWith('<system-reminder>');
  }
}
