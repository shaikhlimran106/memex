import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:path/path.dart' as p;

import 'package:memex/data/services/file_operation_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/agent/pkm_agent/pkm_stats_service.dart';

/// Harness control plane for the SuperAgent and its capture child workers.
///
/// Recovers the genuinely-valuable parts of the old fixed pipeline without
/// re-imposing rigid gates, via dart_agent_core's post-tool / turn-completion
/// hooks:
///
/// - **PKM structural-health reminders**: when an agent reads a `/PKM` file,
///   append the same "file too long / fragmented / churned" advice the old
///   pkm_agent's custom Read tool produced. PKM organization now happens inside
///   a capture *child* worker, so this is wired into BOTH the parent (for
///   conversational/repair work it does itself, via [buildPostToolCallHook])
///   and the child workers (via [buildChildPostToolCallHook]).
/// - **Idle-skill reminder** (parent only): when the parent keeps a skill
///   active but unused for several turns, gently suggest deactivating it.
///
/// The earlier "you saved a card but didn't organize it into PKM" nudge has
/// been removed: capture now fans PKM out as a parallel child worker by design,
/// so the nudge is obsolete.
class SuperAgentHarness {
  SuperAgentHarness._();

  /// Per-session, per-turn skill-usage tracking, keyed by sessionId. Pure
  /// memory, never persisted. Updated by the post-tool hook, read+cleared by
  /// the turn-completion hook.
  static final Map<String, _CaptureTurnState> _captureState = {};

  /// Per-session, cross-turn idle counters: optional-skill name -> number of
  /// consecutive user turns in which none of that skill's tools were used.
  /// Survives across turns within a session (unlike [_captureState]).
  ///
  /// Now that capture fans out to child workers, the SuperAgent itself only
  /// activates a skill for conversational / repair work — typically one skill,
  /// used every turn. So "active but unused for 3 turns straight" cleanly means
  /// the user has moved on, and a gentle deactivate reminder keeps context
  /// focused. (The earlier multi-skill capture flow made this noisy; that flow
  /// is gone.)
  static final Map<String, Map<String, int>> _skillIdleTurns = {};

  /// Consecutive idle user turns before reminding to deactivate a skill.
  static const _skillIdleReminderThreshold = 3;

  static _CaptureTurnState _stateFor(String sessionId) =>
      _captureState.putIfAbsent(sessionId, () => _CaptureTurnState());

  /// Parent post-tool hook: idle-skill tracking + PKM structural-health
  /// reminders on `/PKM` reads.
  static PostToolCallHook buildPostToolCallHook(String userId) {
    return (StatefulAgent agent, AgentState state,
        FunctionExecutionResult result) async {
      final sessionId = state.sessionId;

      // Note which optional skill (if any) this tool belongs to, so the
      // turn-completion hook can age idle-skill counters.
      if (!result.isError) {
        final owningSkill = _optionalSkillForTool(agent, result.name);
        if (owningSkill != null) {
          _stateFor(sessionId).usedSkills.add(owningSkill);
        }
      }

      return _pkmHealthPostToolResult(userId, result);
    };
  }

  /// Child-worker post-tool hook: PKM structural-health reminders only. Child
  /// workers don't persist across turns and don't manage their own skill
  /// lifecycle, so the idle-skill tracking does not apply to them. Harmless on
  /// card/schedule workers — it only fires when a `/PKM` file is actually read.
  static PostToolCallHook buildChildPostToolCallHook(String userId) {
    return (StatefulAgent agent, AgentState state,
            FunctionExecutionResult result) async =>
        _pkmHealthPostToolResult(userId, result);
  }

  static Future<PostToolCallResult> _pkmHealthPostToolResult(
      String userId, FunctionExecutionResult result) async {
    if (result.name == 'Read' && !result.isError) {
      final reminder = await _buildPkmHealthReminder(userId, result);
      if (reminder != null) {
        return PostToolCallResult(reminderMessage: UserMessage.text(reminder));
      }
    }
    return const PostToolCallResult();
  }

  /// Build the turn-completion hook for a given user. Ages the idle-skill
  /// counters and (re)builds or clears the deactivate reminder.
  static TurnCompletionHook buildTurnCompletionHook(String userId) {
    return (StatefulAgent agent, AgentState state,
        ModelMessage finalMessage) async {
      final sessionId = state.sessionId;
      final turn = _captureState[sessionId];

      _ageIdleSkillsAndBuildReminder(
        agent,
        state,
        turn?.usedSkills ?? const <String>{},
      );
      _captureState.remove(sessionId);
      return const TurnCompletionResult.accept();
    };
  }

  // --- helpers ---

  /// Name of the optional (non-force-active) skill that owns [toolName], or
  /// null if the tool is built-in / belongs to a force-active skill / unknown.
  /// Read dynamically from the agent's skill registry.
  static String? _optionalSkillForTool(StatefulAgent agent, String toolName) {
    final skills = agent.skills;
    if (skills == null) return null;
    for (final skill in skills) {
      if (skill.forceActivate) continue;
      final tools = skill.tools;
      if (tools == null) continue;
      if (tools.any((t) => t.name == toolName)) return skill.name;
    }
    return null;
  }

  /// At the end of a user turn, age the idle counter for each active optional
  /// skill (reset to 0 if any of its tools were used this turn, else +1; drop
  /// counters for skills no longer active), then (re)build the idle-skill
  /// reminder in [state.systemReminders] or clear it when nothing is idle.
  ///
  /// systemReminders is a sticky, self-correcting channel: the reminder is
  /// re-derived from current state every turn, so as soon as the model
  /// deactivates the skill or uses it again, the reminder disappears on its own.
  static void _ageIdleSkillsAndBuildReminder(
    StatefulAgent agent,
    AgentState state,
    Set<String> usedSkills,
  ) {
    final sessionId = state.sessionId;
    final optionalActive = (state.activeSkills ?? const <String>[]).where((n) {
      final skill = agent.skills?.where((s) => s.name == n).firstOrNull;
      return skill != null && !skill.forceActivate;
    }).toSet();

    final counters = _skillIdleTurns.putIfAbsent(sessionId, () => {});
    counters.removeWhere((name, _) => !optionalActive.contains(name));
    for (final name in optionalActive) {
      counters[name] = usedSkills.contains(name) ? 0 : (counters[name] ?? 0) + 1;
    }

    final idle = counters.entries
        .where((e) => e.value >= _skillIdleReminderThreshold)
        .map((e) => e.key)
        .toList();

    // Bound memory: with no active optional skills there's nothing to track.
    if (counters.isEmpty) _skillIdleTurns.remove(sessionId);

    const reminderKey = 'idle_skills';
    if (idle.isEmpty) {
      state.systemReminders.remove(reminderKey);
    } else {
      state.systemReminders[reminderKey] =
          'These skills have stayed active but unused for the last '
          '$_skillIdleReminderThreshold turns: ${idle.join(', ')}. '
          "If you're done with them, call "
          "deactivate_skills(['${idle.join("', '")}']) to keep your context "
          'focused. If you still need them, ignore this.';
    }
  }

  static bool _isUnderPkm(String path) {
    final norm = path.startsWith('/') ? path : '/$path';
    return norm == '/PKM' || norm.startsWith('/PKM/');
  }

  static String? _argString(String argumentsJson, String key) {
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is Map && decoded[key] is String) {
        return decoded[key] as String;
      }
    } catch (_) {}
    return null;
  }

  /// Reproduces the structural-health reminders the old pkm_agent custom Read
  /// tool appended, but only for `/PKM` reads, delivered via the post-tool
  /// hook. Returns null when no reminder applies.
  static Future<String?> _buildPkmHealthReminder(
      String userId, FunctionExecutionResult result) async {
    final filePath = _argString(result.arguments, 'file_path');
    if (filePath == null || !_isUnderPkm(filePath)) return null;

    final workingDirectory =
        FileSystemService.instance.getWorkspacePath(userId);
    final reminders = <String>[];

    // 1. Line count check (from the read result content text).
    final text = _resultText(result);
    final lineCount = '\n'.allMatches(text).length + 1;
    if (lineCount >= 2000) {
      reminders.add(
          'The file "$filePath" contains $lineCount lines, exceeding the 2000-line limit. Adjust it to comply with P.A.R.A. structure after processing.');
    } else if (lineCount > 1000) {
      reminders.add(
          'The file "$filePath" contains $lineCount lines. Consider whether the P.A.R.A. structure is reasonable after processing.');
    }

    // 2. Directory fragmentation check.
    try {
      final parentDir = p.dirname(filePath);
      final grepResult = await FileOperationService.instance.grepFiles(
        pattern: 'fact_id',
        searchPath: parentDir,
        workingDirectory: workingDirectory,
        outputMode: 'count',
        r: false,
      );
      if (!grepResult.startsWith('No matches found')) {
        var fragmented = 0;
        final infos = <String>[];
        for (final line in grepResult.split('\n')) {
          if (line.startsWith('(Output limited')) continue;
          final lastColon = line.lastIndexOf(':');
          if (lastColon == -1) continue;
          final fPath = line.substring(0, lastColon).trim();
          final count = int.tryParse(line.substring(lastColon + 1).trim());
          if (count != null && count <= 1) {
            fragmented++;
            infos.add('${p.basename(fPath)} ($count)');
          }
        }
        if (fragmented > 5) {
          reminders.add(
              'The directory "$parentDir" has $fragmented files with only one fact_id reference each: ${infos.join(", ")}. Consider consolidating to avoid excessive fragmentation after processing.');
        }
      }
    } catch (_) {
      // ignore directory access errors
    }

    // 3. Filename date check.
    final filename = p.basename(filePath);
    if (RegExp(r'20\d{2}-?(?:0[1-9]|1[0-2])-?(?:0[1-9]|[12]\d|3[01])')
        .hasMatch(filename)) {
      reminders.add(
          'The file "$filename" contains a date in its filename. Reconsider whether this name is reasonable (P.A.R.A. names should be topic-based, not time-based) after processing.');
    }

    // 4. Frequent edit check.
    try {
      final editCount =
          await PkmStatsService.instance.getRecentEditCount(userId, filePath);
      if (editCount >= 3) {
        final hasDate = RegExp(r'(20\d{2})').hasMatch(filename);
        reminders.add(hasDate
            ? 'The file "$filename" was modified in $editCount of the last 5 inputs and has a date in its name, suggesting a time-based log. Consider renaming to a topic-based name or splitting it.'
            : 'The file "$filename" was modified in $editCount of the last 5 inputs, suggesting its name is too generic. Consider renaming it to be more specific or splitting it.');
      }
    } catch (_) {
      // ignore stats errors
    }

    if (reminders.isEmpty) return null;
    return '<system-reminder>\nP.A.R.A. structural health for the file you just read:\n- ${reminders.join('\n- ')}\n</system-reminder>';
  }

  static String _resultText(FunctionExecutionResult result) {
    final buffer = StringBuffer();
    for (final part in result.content) {
      if (part is TextPart) buffer.write(part.text);
    }
    return buffer.toString();
  }
}

/// Per-session, per-turn skill-usage tracking. Reset (removed) on turn
/// completion. Feeds the idle-skill reminder.
class _CaptureTurnState {
  /// Optional skills whose tools were used during this user turn.
  final Set<String> usedSkills = {};
}
