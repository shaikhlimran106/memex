import 'package:dart_agent_core/dart_agent_core.dart';

/// SuperAgent skill for explicitly managing the user's long-term profile
/// memory (write path).
///
/// Memory is normally accumulated automatically in the background: when a card
/// is saved, its fact is enqueued to [MemorySyncService], batched, and curated
/// by the MemoryAgent. This skill is the *interactive* override — it is only
/// activated when the user explicitly asks to remember, save, update, or
/// correct a long-term fact / preference about themselves. Keeping it off the
/// always-on system prompt avoids nudging the agent to write memory on every
/// turn.
///
/// Read access is unaffected: the SuperAgent always sees existing memory via
/// the `user_memory` system reminder, with or without this skill active.
///
/// The system prompt and tools are built from a [MemoryManagement] instance
/// (which needs an async load) and injected by the caller, since [Skill]
/// requires them synchronously at construction.
class MemoryManagementSkill extends Skill {
  MemoryManagementSkill({
    required super.systemPrompt,
    required super.tools,
    super.forceActivate,
  }) : super(
          name: 'manage_memory',
          description:
              'Records or updates the user\'s long-term profile memory '
              '(durable facts, preferences, identity, relationships, habits). '
              'Use ONLY when the user explicitly asks to remember, save, note, '
              'update, or correct something about themselves for the long term '
              '(e.g. "remember that I\'m allergic to peanuts", "update my job '
              'title", "forget that I live in Beijing"). Routine capture does '
              'NOT need this skill — new records accumulate into memory '
              'automatically in the background.',
        );
}
