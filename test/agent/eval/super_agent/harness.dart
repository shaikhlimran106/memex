import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/eval.dart';
import 'package:memex/agent/state_util.dart';
import 'package:memex/agent/super_agent/super_agent.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/agent_definitions.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/utils/time_context.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;

/// SuperAgent capability harness. One session per trial; each session
/// 1. seeds the per-user workspace from the task fixture (optional shared
///    `base_fixture` + per-task `fixture_dir` overlay),
/// 2. snapshots the existing Cards / PKM / Templates / Schedule before the run,
/// 3. drives the production `SuperAgent.createAgent` + `agent.run` chat
///    codepath — once per "turn" (single `content`, or a `turns` list for
///    multi-turn scenarios) on the SAME stateful agent so history accumulates,
/// 4. snapshots everything again, assembles an [Outcome] for the code graders,
///    and writes a rich **judgment package** JSON (outside the workspace, which
///    gets deleted on dispose) so a human/LLM judge can score the qualitative
///    dimensions after the run.
///
/// Generic execution trajectory (messages, tool calls, token metrics) is
/// recorded by dart_agent_core's eval runner through [EvalContext.controller],
/// so the harness returns an empty [Transcript] and lets the framework fill it.
/// The harness *also* attaches its own lightweight tool-call listener so the
/// judgment package and a couple of graders can see what tools ran.
class SuperAgentHarnessFactory implements AgentHarnessFactory {
  const SuperAgentHarnessFactory();

  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async =>
      _SuperAgentSession(task: task, trial: trial, ctx: context);
}

/// Where judgment packages are written. Lives under the gitignored
/// `.state_dir/` next to traces/reports, NOT inside the per-trial workspace
/// (which `dispose` deletes).
const judgmentDirPath = '.state_dir/.eval_judgment';

class _SuperAgentSession implements AgentHarnessSession {
  final EvalTask task;
  final Trial trial;
  final EvalContext ctx;

  _SuperAgentSession({
    required this.task,
    required this.trial,
    required this.ctx,
  });

  @override
  Future<({Transcript transcript, Outcome outcome})> run() async {
    final userId = ctx.metadata['user_id'] as String;
    final suiteDir = ctx.metadata['suite_dir'] as String;
    final fs = FileSystemService.instance;

    // 1. Seed workspace (base then overlay).
    final destWorkspace = Directory(fs.getWorkspacePath(userId));
    final baseFixture = task.input['base_fixture'] as String?;
    if (baseFixture != null && baseFixture.isNotEmpty) {
      final baseDir = Directory(p.join(suiteDir, baseFixture));
      if (!baseDir.existsSync()) {
        throw StateError('base_fixture does not exist on disk: ${baseDir.path}');
      }
      await _copyDirectory(baseDir, destWorkspace);
    }
    final fixtureRel = task.input['fixture_dir'] as String?;
    if (fixtureRel != null && fixtureRel.isNotEmpty) {
      final fixtureDir = Directory(p.join(suiteDir, fixtureRel));
      if (!fixtureDir.existsSync()) {
        throw StateError(
          'fixture_dir does not exist on disk: ${fixtureDir.path}',
        );
      }
      await _copyDirectory(fixtureDir, destWorkspace);
    }

    final turns = _resolveTurns(task.input);
    final scene = task.input['scene'] as String? ?? 'super_agent_home';
    final quickQuery = task.input['quick_query'] == true;

    // 2. Before-snapshots of every subtree a turn might touch.
    final beforeCards = await _snapshotCardPaths(fs, userId);
    final pkmRoot = Directory(fs.getPkmPath(userId));
    final templatesRoot = Directory(fs.getTemplatesPath(userId));
    final beforePkm = await _snapshotTree(pkmRoot);
    final beforeTemplates = await _snapshotTree(templatesRoot);
    final beforeSchedule = await _readScheduleRaw(fs, userId);

    final resources = await UserStorage.getAgentLLMResources(
      AgentDefinitions.chatAgent,
      defaultClientKey: LLMConfig.defaultClientKey,
    );

    final sessionId =
        '${trial.taskId}_${trial.trialIndex}_${DateTime.now().microsecondsSinceEpoch}';
    final state = await loadOrCreateAgentState(sessionId, {
      'userId': userId,
      'scene': scene,
    });

    final agent = await SuperAgent.createAgent(
      client: resources.client,
      modelConfig: resources.modelConfig,
      userId: userId,
      name: 'memex_agent',
      state: state,
      controller: ctx.controller,
      quickQuery: quickQuery,
      additionalSystemPrompt: _additionalSystemPrompt,
      // Optional per-task override so a stress task can force context
      // compression with a realistic-length session instead of needing to
      // naturally accumulate the 64k production quota. Defaults to production.
      compressionTokenThreshold:
          (task.input['compression_token_threshold'] as int?) ?? 64000,
    );

    // Lightweight tool-call capture for the judgment package (the framework's
    // transcript isn't available here in the harness).
    final toolCalls = <Map<String, dynamic>>[];
    ctx.controller.on((BeforeToolCallEvent event) {
      toolCalls.add({
        'name': event.functionCall.name,
        'arguments': event.functionCall.arguments,
      });
    });

    // 3. Drive each turn on the same agent so chat history accumulates.
    final replies = <String>[];
    var ranOk = true;
    String? runError;
    for (var i = 0; i < turns.length; i++) {
      final userMessages = await _buildUserTurn(
        turn: turns[i],
        scene: scene,
        isFirstTurn: i == 0,
        userId: userId,
        fs: fs,
      );
      try {
        final result = await agent.run(userMessages);
        replies.add(_lastTextOutput(result));
      } catch (e) {
        ranOk = false;
        runError = e.toString();
        replies.add('[run error: $e]');
        break;
      }
    }

    // 4. After-snapshots + diffs.
    final afterCards = await _snapshotCardPaths(fs, userId);
    final afterPkm = await _snapshotTree(pkmRoot);
    final afterTemplates = await _snapshotTree(templatesRoot);
    final afterSchedule = await _readScheduleRaw(fs, userId);

    final newCardPaths =
        afterCards.keys.toSet().difference(beforeCards.keys.toSet());
    final newCards = <Map<String, dynamic>>[];
    for (final path in newCardPaths) {
      final factId = fs.factIdFromCardPath(path);
      if (factId == null) continue;
      final card = await fs.readCardFile(userId, factId);
      if (card == null) continue;
      newCards.add(_describeCard(card, afterCards[path] ?? ''));
    }

    // Modified pre-existing cards (e.g. an edit/repair of a seeded card).
    final modifiedCards = <Map<String, dynamic>>[];
    for (final entry in afterCards.entries) {
      if (!beforeCards.containsKey(entry.key)) continue;
      if (beforeCards[entry.key] == entry.value) continue;
      final factId = fs.factIdFromCardPath(entry.key);
      if (factId == null) continue;
      final card = await fs.readCardFile(userId, factId);
      modifiedCards.add({
        'fact_id': factId,
        'before_yaml': beforeCards[entry.key],
        'after_yaml': entry.value,
        if (card != null) ...{
          'title': card.title,
          'fact': card.fact,
          'status': card.status,
          'template_ids': card.uiConfigs.map((c) => c.templateId).toList(),
        },
      });
    }

    // PKM files created or modified during the run.
    final pkmWritten = _diffTree(beforePkm, afterPkm);

    // Templates: a custom dynamic UI template appears as a new/changed
    // `<template_id>/view.html` under _UserSettings/Templates.
    final templateFilesChanged = _diffTree(beforeTemplates, afterTemplates);
    final templatesCreated = <String>{};
    for (final rel in templateFilesChanged.keys) {
      // rel is like "<template_id>/view.html" or "<template_id>/meta.json".
      final seg = p.split(rel);
      if (seg.isNotEmpty) templatesCreated.add(seg.first);
    }

    // Built-in template ids (used to tell custom templates from native ones).
    final allNewCardTemplateIds = <String>{
      for (final c in newCards)
        ...((c['template_ids'] as List?)?.cast<String>() ?? const []),
    };
    final customTemplateIdsOnCards = allNewCardTemplateIds
        .where((id) => !_builtInTemplateIds.contains(id.toLowerCase()))
        .toList();

    final schedulePending = _schedulePendingTitles(afterSchedule);
    final schedulePendingBefore = _schedulePendingTitles(beforeSchedule);
    final newSchedulePending = schedulePending.length >
            schedulePendingBefore.length
        ? schedulePending.sublist(schedulePendingBefore.length)
        : (schedulePending.toSet().difference(schedulePendingBefore.toSet()))
            .toList();

    final completedNewCards =
        newCards.where((c) => c['status'] == 'completed').toList();

    // Compression observability (removes the prior blind spot): peak prompt
    // tokens seen across the whole session, and whether compression actually
    // fired (it archives history into an episodic memory).
    var peakPromptTokens = 0;
    for (final u in agent.state.usages) {
      if (u.promptTokens > peakPromptTokens) peakPromptTokens = u.promptTokens;
    }
    final episodicCount = agent.state.history.episodicMemories.length;
    final retrieveMemoryCalls =
        toolCalls.where((t) => t['name'] == 'retrieve_memory').length;

    final environmentState = <String, dynamic>{
      'ran_ok': ranOk,
      if (runError != null) 'run_error': runError,
      'quick_query': quickQuery,
      'turn_count': turns.length,
      'peak_prompt_tokens': peakPromptTokens,
      'compression_fired': episodicCount > 0,
      'episodic_memory_count': episodicCount,
      'retrieve_memory_calls': retrieveMemoryCalls,
      'new_card_count': newCards.length,
      'completed_new_card_count': completedNewCards.length,
      'modified_card_count': modifiedCards.length,
      'modified_card_fact_ids':
          modifiedCards.map((c) => c['fact_id']).toList(),
      'new_cards': newCards,
      'custom_template_ids_on_cards': customTemplateIdsOnCards,
      'templates_created': templatesCreated.toList(),
      'pkm_files_written': pkmWritten.keys.toList(),
      'schedule_pending_titles': schedulePending,
      'new_schedule_pending_titles': newSchedulePending,
      'tool_names': toolCalls.map((t) => t['name']).toList(),
    };

    // Write the judgment package for qualitative (human/LLM) scoring. Done
    // here, before dispose() deletes the workspace.
    await _writeJudgmentPackage(
      turns: turns
          .map((t) => t.images.isEmpty
              ? t.text
              : '${t.text} [attachments: ${t.images.map((i) => i.fsFilename).join(', ')}]')
          .toList(),
      replies: replies,
      newCards: newCards,
      modifiedCards: modifiedCards,
      pkmWritten: pkmWritten,
      templateFilesChanged: templateFilesChanged,
      schedulePending: schedulePending,
      newSchedulePending: newSchedulePending,
      toolCalls: toolCalls,
      environmentState: environmentState,
    );

    return (
      transcript: Transcript(
        messages: const [],
        toolCalls: const [],
        metrics: const TranscriptMetrics(
          nTurns: 0,
          nToolCalls: 0,
          nTotalTokens: 0,
        ),
      ),
      outcome: Outcome(environmentState: environmentState),
    );
  }

  @override
  Future<void> dispose() async {}

  Future<void> _writeJudgmentPackage({
    required List<String> turns,
    required List<String> replies,
    required List<Map<String, dynamic>> newCards,
    required List<Map<String, dynamic>> modifiedCards,
    required Map<String, String> pkmWritten,
    required Map<String, String> templateFilesChanged,
    required List<String> schedulePending,
    required List<String> newSchedulePending,
    required List<Map<String, dynamic>> toolCalls,
    required Map<String, dynamic> environmentState,
  }) async {
    final dir = Directory(judgmentDirPath)..createSync(recursive: true);
    final file = File(p.join(
      dir.path,
      '${trial.taskId}_${trial.trialIndex}.json',
    ));
    final pkg = {
      'task_id': trial.taskId,
      'trial_index': trial.trialIndex,
      'description': task.description,
      'user_turns': turns,
      'agent_replies': replies,
      'new_cards': newCards,
      'modified_cards': modifiedCards,
      'pkm_files_written': pkmWritten,
      'templates_changed': templateFilesChanged,
      'schedule_pending_titles': schedulePending,
      'new_schedule_pending_titles': newSchedulePending,
      'tool_calls': toolCalls,
      'environment_state': environmentState,
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(pkg));
  }

  /// Mirrors what `ChatService` appends to the default SuperAgent session.
  /// Behavioral guidance now lives in `superAgentSystemPrompt`; only the
  /// dynamic language instruction is appended per session.
  static final String _additionalSystemPrompt =
      """## Language\n${UserStorage.l10n.chatLanguageInstruction}""";

  /// Single `content` → one turn; a `turns` list → multi-turn. Each turn entry
  /// is either a plain string (text-only) or an object `{text, images}` where
  /// `images` is a list of attachment descriptors (a bare filename string, or
  /// `{file, original_name}`). The named files must exist under the seeded
  /// `Facts/assets/` so the model can "see" them and `save_timeline_card`'s
  /// asset validation passes. Empty input is treated as one empty turn so the
  /// agent still gets driven once.
  List<_Turn> _resolveTurns(Map<String, dynamic> input) {
    final raw = input['turns'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map(_parseTurn).toList();
    }
    return [_Turn(input['content'] as String? ?? '')];
  }

  _Turn _parseTurn(dynamic entry) {
    if (entry is Map) {
      final text = (entry['text'] ?? entry['content'] ?? '').toString();
      return _Turn(text, images: _parseTurnImages(entry['images']));
    }
    return _Turn(entry.toString());
  }

  List<_TurnImage> _parseTurnImages(dynamic raw) {
    if (raw is! List) return const [];
    final out = <_TurnImage>[];
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        out.add(_TurnImage(item.trim()));
      } else if (item is Map && item['file'] is String) {
        out.add(_TurnImage(
          (item['file'] as String).trim(),
          originalName: item['original_name'] as String?,
        ));
      }
    }
    return out;
  }

  /// Mirror the per-turn `<system-reminder>` block + plain user text that
  /// `ChatService.sendMessage` assembles. The scene context is only injected on
  /// the first turn (it describes the entry point, not each message). When the
  /// turn carries images, mirror `ChatService._buildAttachmentContext` (the
  /// `![image](fs://…)` reference block inside the reminder) and append a real
  /// `ImagePart` per attachment, read from the seeded `Facts/assets/`.
  Future<List<LLMMessage>> _buildUserTurn({
    required _Turn turn,
    required String scene,
    required bool isFirstTurn,
    required String userId,
    required FileSystemService fs,
  }) async {
    final now = DateTime.now();
    final sceneContext = isFirstTurn ? _sceneContext(scene) : '';
    final reminderSections = <String>[
      'User Message Time: ${formatLocalDateTimeWithZone(now)}',
      'Current Local Time: ${formatLocalDateTimeWithZone(now)}',
      if (sceneContext.isNotEmpty) sceneContext,
      if (turn.images.isNotEmpty) _attachmentReminder(turn.images, scene),
    ];
    final combinedReminder =
        '<system-reminder>\n${reminderSections.join('\n\n')}\n</system-reminder>';

    final parts = <UserContentPart>[
      TextPart(combinedReminder),
      TextPart(turn.text.isEmpty && turn.images.isEmpty
          ? 'User sent an empty message.'
          : turn.text.isEmpty
              ? 'User sent ${turn.images.length} image attachment(s).'
              : turn.text),
    ];
    final assetsPath = fs.getAssetsPath(userId);
    for (final img in turn.images) {
      final file = File(p.join(assetsPath, img.fsFilename));
      if (!await file.exists()) {
        throw StateError(
            'turn image not found under Facts/assets: ${img.fsFilename}');
      }
      final b64 = base64Encode(await file.readAsBytes());
      parts.add(ImagePart(b64, _mimeForFilename(img.fsFilename)));
    }
    return [UserMessage(parts)];
  }

  /// Mirrors `ChatService._buildAttachmentContext`: the `![image](fs://…)`
  /// reference block that tells the agent how attachments are identified and
  /// that the references go verbatim into a card's `assets` field.
  String _attachmentReminder(List<_TurnImage> images, String scene) {
    final b = StringBuffer()
      ..writeln('The user attached ${images.length} image(s).')
      ..writeln(scene == 'super_agent_home'
          ? 'This is the central Super Agent entry. Media-only uploads are usually capture intent; inspect them and decide the likely goal unless the user clearly asks a question or requests an edit.'
          : 'Inspect the attached image(s) and use them to address the user request.')
      ..writeln(
          'Each attachment is identified by a `![image](fs://…)` reference below. '
          'If you save a timeline card for this input, copy the relevant '
          "references verbatim into the card's `assets` field.");
    for (var i = 0; i < images.length; i++) {
      final img = images[i];
      b.writeln('${i + 1}. ![image](fs://${img.fsFilename})'
          '${img.originalName == null ? '' : ', original_name: ${img.originalName}'}'
          ', mime_type: ${_mimeForFilename(img.fsFilename)}');
    }
    return b.toString().trimRight();
  }

  String _mimeForFilename(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  String _sceneContext(String scene) {
    switch (scene) {
      case 'super_agent_home':
        return 'The user opened you from the central Memex entry point. They may want to record something into the timeline, ask about existing memory, request edits, or configure the app. Act as the trusted Super Agent entry rather than a one-shot chatbot: decide the likely intent, continue useful low-risk work, and only ask clarification for genuinely risky or conflicting actions. If the user attaches images, inspect them before deciding.';
      case 'assistant_timeline_card_detail':
        return 'The user is currently viewing a **Timeline Card Detail Page**. They may want to edit, analyze, or discuss this specific card.';
      default:
        return '';
    }
  }
}

/// One eval turn: user text plus optional image attachments. A plain-string
/// turn entry parses to text-only; an object entry may carry `images`.
class _Turn {
  final String text;
  final List<_TurnImage> images;
  const _Turn(this.text, {this.images = const []});
}

/// An image attachment for a turn. [fsFilename] is the file's name under the
/// seeded `Facts/assets/` and also the `fs://` id the agent sees.
class _TurnImage {
  final String fsFilename;
  final String? originalName;
  const _TurnImage(this.fsFilename, {this.originalName});
}

String _lastTextOutput(List<LLMMessage> result) {
  for (var i = result.length - 1; i >= 0; i--) {
    final m = result[i];
    if (m is ModelMessage && (m.textOutput?.trim().isNotEmpty ?? false)) {
      return m.textOutput!.trim();
    }
  }
  return '';
}

/// Built-in (native) template ids shipped by manage_timeline_card. Used to
/// distinguish a dynamically-designed custom template from a native one.
const _builtInTemplateIds = {
  'classic_card',
  'compact',
  'compact_card',
  'link',
  'person',
  'place',
  'spec_sheet',
  'transaction',
  'metric',
  'rating',
  'mood',
  'progress',
  'event',
  'duration',
  'task',
  'routine',
  'procedure',
  'snippet',
  'article',
  'conversation',
  'quote',
  'snapshot',
  'gallery',
  'video',
};

Map<String, dynamic> _describeCard(CardData card, String yaml) {
  return {
    'fact_id': card.factId,
    'status': card.status,
    'title': card.title,
    'template_ids': card.uiConfigs.map((c) => c.templateId).toList(),
    'ui_configs': card.uiConfigs
        .map((c) => {'template_id': c.templateId, 'data': c.data})
        .toList(),
    'fact': card.fact,
    'assets': card.assets,
    'tags': card.tags,
    'has_insight': card.insight != null &&
        (card.insight!.text != null && card.insight!.text!.trim().isNotEmpty),
    'insight_text': card.insight?.text,
    'yaml': yaml,
  };
}

/// Map of absolute card path -> file contents, for diffing before/after.
Future<Map<String, String>> _snapshotCardPaths(
  FileSystemService fs,
  String userId,
) async {
  final out = <String, String>{};
  final paths = await fs.listAllCardFiles(userId);
  for (final path in paths) {
    out[path] = await _readBlob(path);
  }
  return out;
}

/// Map of path-relative-to-[root] -> file contents for everything under [root].
Future<Map<String, String>> _snapshotTree(Directory root) async {
  final out = <String, String>{};
  if (!await root.exists()) return out;
  await for (final entry in root.list(recursive: true, followLinks: false)) {
    if (entry is! File) continue;
    final rel = p.relative(entry.path, from: root.path);
    out[rel] = await entry.readAsString();
  }
  return out;
}

/// Files in [after] that are new or whose content changed vs [before].
Map<String, String> _diffTree(
  Map<String, String> before,
  Map<String, String> after,
) {
  final out = <String, String>{};
  for (final e in after.entries) {
    if (!before.containsKey(e.key) || before[e.key] != e.value) {
      out[e.key] = e.value;
    }
  }
  return out;
}

Future<Map<String, dynamic>?> _readScheduleRaw(
  FileSystemService fs,
  String userId,
) async {
  try {
    return await fs.readScheduleStateRaw(userId);
  } catch (_) {
    return null;
  }
}

List<String> _schedulePendingTitles(Map<String, dynamic>? schedule) {
  if (schedule == null) return const [];
  final pending = schedule['pending'];
  if (pending is! List) return const [];
  return pending
      .whereType<Map>()
      .map((m) => (m['title'] ?? '').toString())
      .where((t) => t.isNotEmpty)
      .toList();
}

Future<String> _readBlob(String path) async {
  final f = File(path);
  if (!await f.exists()) return '';
  return f.readAsString();
}

/// Recursive `cp -R` for fixture seeding.
Future<void> _copyDirectory(Directory src, Directory dst) async {
  if (!await src.exists()) return;
  await dst.create(recursive: true);
  await for (final entry in src.list(recursive: false)) {
    final name = p.basename(entry.path);
    if (entry is Directory) {
      await _copyDirectory(entry, Directory(p.join(dst.path, name)));
    } else if (entry is File) {
      await entry.copy(p.join(dst.path, name));
    }
  }
}
