import 'package:dart_agent_core/dart_agent_core.dart';

import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/agent/skills/knowledge_insight/knowledge_insight_skill.dart';
import 'package:memex/agent/skills/manage_pkm/pkm_skill.dart';
import 'package:memex/agent/skills/manage_timeline_card/timeline_card_skill.dart';
import 'package:memex/agent/skills/schedule_aggregation/schedule_aggregation_skill.dart';
import 'package:memex/agent/skills/timeline_diagnostics/timeline_diagnostics_skill.dart';
import 'package:memex/agent/super_agent/subagent/super_agent_child.dart';
import 'package:memex/data/services/location_context_service.dart';
import 'package:memex/utils/logger.dart';

final _logger = getLogger('DelegateSubagent');

/// A skill SuperAgent is allowed to hand to a child worker, plus the
/// (security-relevant) workspace roots a child running it may WRITE to.
///
/// The model names skills; the **write scope is decided here in code**, never
/// by the model — so a delegated child can never widen its own write access by
/// asking for it. `build` returns a fresh instance each call because
/// [Skill.forceActivate] is mutable per-instance.
class _DelegatableSkill {
  final Skill Function() build;
  final List<String> writeRoots;
  const _DelegatableSkill(this.build, this.writeRoots);
}

/// Registry of delegatable skills. This is the extension point: adding a
/// research/insight worker later means adding an entry here (and letting the
/// model name it), not adding a new tool or a new agent type.
final Map<String, _DelegatableSkill> _delegatableSkills = {
  // Card worker writes the card itself through its skill tool (service-backed);
  // generic Write is only needed to author a custom template's view.html.
  'manage_timeline_card': _DelegatableSkill(
    () => TimelineCardSkill(),
    const ['/_UserSettings/Templates'],
  ),
  'dynamic_timeline_ui': _DelegatableSkill(
    () => DynamicTimelineUiSkill(),
    const ['/_UserSettings/Templates'],
  ),
  // PKM worker authors P.A.R.A markdown via generic Write/Edit under /PKM.
  'manage_pkm': _DelegatableSkill(
    () => PkmSkill(workingDirectory: '/PKM'),
    const ['/PKM'],
  ),
  // Schedule worker writes schedule_state through its own service-backed tools,
  // so it needs no generic write root.
  'update_schedule_aggregation': _DelegatableSkill(
    () => ScheduleAggregationSkill(),
    const [],
  ),
  // Read-only diagnostics — useful for research / validation / card-repair
  // investigation workers.
  'timeline_diagnostics': _DelegatableSkill(
    () => TimelineDiagnosticsSkill(),
    const [],
  ),
  // Knowledge-insight generation. Writes through service-backed tools (like
  // schedule), so it needs no generic write root.
  'update_knowledge_insight': _DelegatableSkill(
    () => KnowledgeInsightSkill(),
    const [],
  ),
};

ChildToolProfile _profileFromWire(String? v) {
  switch (v) {
    case 'none':
      return ChildToolProfile.none;
    case 'full':
      return ChildToolProfile.full;
    case 'read':
    default:
      return ChildToolProfile.read;
  }
}

/// Builds the generic `delegate_to_subagent` tool: spawn ONE temporary child
/// worker, shaped by a base tool [profile] plus a list of skills (some
/// force-activated), hand it a bounded task, and return its structured result.
///
/// This is a general delegation primitive, NOT a record-capture pipeline.
/// SuperAgent decides how many children to run and how to shape each. To run
/// several in PARALLEL, emit multiple `delegate_to_subagent` calls in the SAME
/// turn — the agent loop executes a turn's tool calls concurrently. The parent
/// owns merging the results and the final user-facing reply.
Tool buildDelegateToSubagentTool() {
  final skillNames = _delegatableSkills.keys.toList();
  return Tool(
    name: 'delegate_to_subagent',
    description:
        'Delegate ONE bounded task to a temporary child worker and get back a '
        'structured result. Shape the worker with a base-tool `profile` and a '
        'list of `skills` (mark the core ones force_activate=true). The worker '
        'is a specialist: it brings its own skill expertise, its own file tools '
        'to inspect the workspace, and the current time and location from its '
        'runtime. It cannot see this conversation, so the `task_brief` supplies '
        'what only you have — but you state the goal, not the procedure, and let '
        'its skill decide how. To run workers in parallel, emit several '
        'delegate_to_subagent calls in the same turn. A worker may return '
        '`no_op` when its branch does not apply — that is normal. Delegatable '
        'skills: ${skillNames.join(', ')}.',
    parameters: {
      'type': 'object',
      'properties': {
        'task_brief': {
          'type': 'string',
          'description':
              'What the worker should accomplish and the context only you can '
                  "provide: the record in the user's own words, any fact_id you "
                  'minted, and a description + reference for any attachment the '
                  'worker cannot see. State the goal, not the steps — do not '
                  'spell out which template, which PKM file/directory, or how to '
                  'structure the entry (the skill decides that), and do not '
                  'include the current time or location (the runtime gives the '
                  'worker its own). Do not reference "the above" or prior turns.',
        },
        'profile': {
          'type': 'string',
          'description':
              'Base file-tool access for the worker: "none" (skill tools only), '
                  '"read" (skill tools + read-only file tools), or "full" '
                  '(adds generic write tools, still confined to the paths its '
                  'skills are allowed to write).',
          'enum': ['none', 'read', 'full'],
        },
        'skills': {
          'type': 'array',
          'description':
              'Skills to give the worker. Each item names a delegatable skill '
                  'and whether to force-activate it (always-on for the run) vs. '
                  'leave it available for the worker to self-activate on demand. '
                  'Delegatable skills: ${skillNames.join(', ')}.',
          'items': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': 'Skill name.',
                'enum': skillNames,
              },
              'force_activate': {
                'type': 'boolean',
                'description':
                    'true = always active for this run; false = available for '
                        'the worker to activate when needed.',
              },
            },
            'required': ['name', 'force_activate'],
          },
        },
      },
      'required': ['task_brief', 'profile', 'skills'],
    },
    executable: (
      String task_brief,
      String profile,
      dynamic skills,
    ) async {
      final context = AgentCallToolContext.current;
      if (context == null) {
        throw StateError(
            'delegate_to_subagent must be called within an agent execution context.');
      }
      final userId = context.state.metadata['userId'] as String;
      final parent = context.agent;

      // Parse + validate the requested skills against the code-side registry.
      final requested = _parseSkills(skills);
      if (requested.isEmpty) {
        throw ArgumentError(
            'skills must list at least one delegatable skill. Available: '
            '${skillNames.join(', ')}.');
      }
      final builtSkills = <Skill>[];
      final writeRoots = <String>{};
      final forceNames = <String>[];
      for (final req in requested) {
        final entry = _delegatableSkills[req.name];
        if (entry == null) {
          throw ArgumentError(
              'Unknown skill "${req.name}". Delegatable skills: '
              '${skillNames.join(', ')}.');
        }
        final skill = entry.build()..forceActivate = req.forceActivate;
        builtSkills.add(skill);
        writeRoots.addAll(entry.writeRoots);
        if (req.forceActivate) forceNames.add(req.name);
      }

      // Time + location are environment facts the model cannot reliably know,
      // so the runtime fetches and injects them — never passed as tool args.
      final contextPacket = <String, dynamic>{
        'captured_at': DateTime.now(),
      };
      try {
        final loc = await LocationContextService.instance.getCurrentContext();
        final reminder = loc.toAgentSystemReminderContent();
        if (reminder != null && reminder.trim().isNotEmpty) {
          contextPacket['location_reminder'] = reminder.trim();
        }
      } catch (e) {
        _logger.warning('Failed to attach location context to child: $e');
      }

      final childName = forceNames.isNotEmpty
          ? '${forceNames.first}_child'
          : '${requested.first.name}_child';

      final config = SuperAgentChildConfig(
        childName: childName,
        taskBrief: task_brief,
        skills: builtSkills,
        toolProfile: _profileFromWire(profile),
        writeRootPaths: writeRoots.toList(),
        contextPacket: contextPacket,
      );

      _logger.info(
          'Delegating to $childName (profile=$profile, skills=$forceNames'
          '+${requested.length - forceNames.length} optional)');

      // runSuperAgentChild never throws — a failed/timed-out child returns a
      // `failed` result so the parent can still merge.
      final result = await runSuperAgentChild(
        config: config,
        client: parent.client,
        modelConfig: parent.modelConfig,
        userId: userId,
      );

      return AgentToolResult(
        content: TextPart(
            '[$childName] status=${result.status.name}\n${result.summary}'),
        metadata: {'child_result': result.toJson()},
      );
    },
  );
}

class _RequestedSkill {
  final String name;
  final bool forceActivate;
  const _RequestedSkill(this.name, this.forceActivate);
}

List<_RequestedSkill> _parseSkills(dynamic skills) {
  final out = <_RequestedSkill>[];
  if (skills is! List) return out;
  for (final raw in skills) {
    if (raw is Map) {
      final name = raw['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final force = raw['force_activate'] == true;
      out.add(_RequestedSkill(name, force));
    } else if (raw is String && raw.trim().isNotEmpty) {
      // Tolerate a bare skill name (defaults to force-activate).
      out.add(_RequestedSkill(raw.trim(), true));
    }
  }
  return out;
}
