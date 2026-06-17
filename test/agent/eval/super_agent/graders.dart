import 'package:dart_agent_core/eval.dart';

/// Outcome schema produced by the super_agent harness. Keys match what
/// `_SuperAgentSession` writes into `Outcome.environmentState`.
abstract class _Keys {
  static const quickQuery = 'quick_query';
  static const newCardCount = 'new_card_count';
  static const completedNewCardCount = 'completed_new_card_count';
  static const modifiedCardCount = 'modified_card_count';
  static const newCards = 'new_cards';
  static const customTemplateIdsOnCards = 'custom_template_ids_on_cards';
  static const templatesCreated = 'templates_created';
  static const newSchedulePending = 'new_schedule_pending_titles';
}

List<Map<String, dynamic>> _newCards(Outcome outcome) {
  final raw = outcome.environmentState[_Keys.newCards];
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}

List<Map<String, dynamic>> _completedNewCards(Outcome outcome) =>
    _newCards(outcome).where((c) => c['status'] == 'completed').toList();

List<String> _strList(Outcome outcome, String key) {
  final raw = outcome.environmentState[key];
  if (raw is! List) return const [];
  return raw.map((e) => e.toString()).toList();
}

/// Verifies a capture turn produced at least one well-formed, completed card:
/// `status == completed`, a non-empty title, at least one ui_config (template),
/// and a preserved fact. These are the non-negotiable "card must be built and
/// complete" invariants for capture intent.
class SuperCaptureCompleteGrader extends CodeGrader {
  SuperCaptureCompleteGrader();

  @override
  String get name => 'super_capture_complete';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final s = outcome.environmentState;
    final completed = _completedNewCards(outcome);
    final completedCount = (s[_Keys.completedNewCardCount] as int?) ?? 0;
    final card = completed.isNotEmpty ? completed.first : null;

    final title = (card?['title'] as String?)?.trim() ?? '';
    final templateIds =
        (card?['template_ids'] as List?)?.cast<String>() ?? const <String>[];
    final fact = (card?['fact'] as String?)?.trim() ?? '';

    return [
      Assertion(
        description: 'created at least one completed card',
        passed: completedCount >= 1,
        actual: 'completed_new_card_count=$completedCount '
            '(new_card_count=${s[_Keys.newCardCount]})',
        expected: '>= 1',
      ),
      Assertion(
        description: 'card has a non-empty title',
        passed: title.isNotEmpty,
        actual: 'title="${_clip(title)}"',
        expected: 'non-empty',
      ),
      Assertion(
        description: 'card has at least one render template (ui_config)',
        passed: templateIds.isNotEmpty,
        actual: 'template_ids=$templateIds',
        expected: 'non-empty',
      ),
      Assertion(
        description: 'card preserved the captured fact text',
        passed: fact.isNotEmpty,
        actual: 'fact="${_clip(fact)}"',
        expected: 'non-empty',
      ),
    ];
  }
}

/// Verifies the agent did NOT create a card. For pure queries / chit-chat /
/// read-only questions, capturing a card is a false-positive. Editing an
/// existing card is allowed and not penalized here.
class SuperNoNewCardGrader extends CodeGrader {
  SuperNoNewCardGrader();

  @override
  String get name => 'super_no_new_card';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final s = outcome.environmentState;
    final newCount = (s[_Keys.newCardCount] as int?) ?? 0;
    final titles = _newCards(outcome).map((c) => c['title']).toList();
    return [
      Assertion(
        description: 'did not create any new card',
        passed: newCount == 0,
        actual: 'new_card_count=$newCount titles=$titles',
        expected: '0',
      ),
    ];
  }
}

/// Verifies read-only mode was honored: a Quick Query turn must not create OR
/// modify any card, and must not execute any mutating write tool.
class SuperReadOnlyRespectedGrader extends CodeGrader {
  SuperReadOnlyRespectedGrader();

  @override
  String get name => 'super_readonly_respected';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final s = outcome.environmentState;
    final quick = s[_Keys.quickQuery] == true;
    final newCount = (s[_Keys.newCardCount] as int?) ?? 0;
    final modCount = (s[_Keys.modifiedCardCount] as int?) ?? 0;

    const mutatingTools = {
      'save_timeline_card',
      'update_timeline_card_insight',
      'save_timeline_template',
      'Write',
      'Edit',
      'move',
      'remove',
      'add_pending_item',
      'update_pending_item',
      'complete_pending_item',
      'set_presentation',
    };
    final mutatingCalls = transcript.toolCalls
        .where((c) => !c.isError && mutatingTools.contains(c.toolName))
        .map((c) => c.toolName)
        .toList();

    return [
      Assertion(
        description: 'task is actually a quick-query trial',
        passed: quick,
        actual: 'quick_query=$quick',
        expected: 'true',
      ),
      Assertion(
        description: 'no card created or modified in read-only mode',
        passed: newCount == 0 && modCount == 0,
        actual: 'new=$newCount modified=$modCount',
        expected: 'new=0 modified=0',
      ),
      Assertion(
        description: 'no mutating write tool executed',
        passed: mutatingCalls.isEmpty,
        actual: 'mutating_calls=$mutatingCalls',
        expected: '[]',
      ),
    ];
  }
}

/// Verifies the capture landed on a sensible template. Partial-credit, modeled
/// on `pkm_routed_correctly`:
///   - 1.0  the new card uses one of [expectedTemplateIds]
///   - 0.0  it used some other template
/// Null score (not applicable) when no completed card was created.
class SuperTemplateChoiceGrader implements Grader {
  final List<String> expectedTemplateIds;

  SuperTemplateChoiceGrader({required this.expectedTemplateIds});

  @override
  String get name => 'super_template_choice';

  @override
  GraderKind get kind => GraderKind.code;

  @override
  double get passThreshold => 1.0;

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final completed = _completedNewCards(outcome);
    if (completed.isEmpty) {
      return Score(
        graderName: name,
        value: null,
        passed: null,
        rationale: 'no completed card to inspect; '
            'super_capture_complete covers that failure',
      );
    }

    final expected = expectedTemplateIds.map((e) => e.toLowerCase()).toSet();
    final usedAll = <String>[];
    bool hit = false;
    for (final card in completed) {
      final ids = (card['template_ids'] as List?)?.cast<String>() ?? const [];
      for (final id in ids) {
        usedAll.add(id);
        if (expected.contains(id.toLowerCase())) hit = true;
      }
    }

    return Score(
      graderName: name,
      value: hit ? 1.0 : 0.0,
      passed: hit,
      assertions: [
        Assertion(
          description: 'used one of $expectedTemplateIds',
          passed: hit,
          actual: 'template_ids=$usedAll',
          expected: 'one of $expectedTemplateIds',
        ),
      ],
      rationale: hit
          ? 'card template matched expected'
          : 'card used $usedAll, none in $expectedTemplateIds',
    );
  }
}

/// Verifies an "update existing record" turn EDITED a pre-seeded card rather
/// than creating a duplicate. Pass requires: at least one card modified, and no
/// brand-new card created. When [expectedFactId] is set, the modified set must
/// include exactly that card.
class SuperModifiedCardGrader extends CodeGrader {
  final String? expectedFactId;

  SuperModifiedCardGrader({this.expectedFactId});

  @override
  String get name => 'super_modified_card';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final s = outcome.environmentState;
    final modCount = (s[_Keys.modifiedCardCount] as int?) ?? 0;
    final newCount = (s[_Keys.newCardCount] as int?) ?? 0;
    final modifiedIds = _strList(outcome, 'modified_card_fact_ids');

    return [
      Assertion(
        description: 'edited an existing card',
        passed: modCount >= 1,
        actual: 'modified_card_count=$modCount ids=$modifiedIds',
        expected: '>= 1',
      ),
      Assertion(
        description: 'did not create a duplicate new card',
        passed: newCount == 0,
        actual: 'new_card_count=$newCount',
        expected: '0',
      ),
      if (expectedFactId != null)
        Assertion(
          description: 'edited the expected card ($expectedFactId)',
          passed: modifiedIds.contains(expectedFactId),
          actual: 'modified=$modifiedIds',
          expected: 'contains $expectedFactId',
        ),
    ];
  }
}

/// Verifies a "no built-in template fits → design a custom HTML card" turn
/// actually produced a custom template AND a completed card that uses it.
/// Pass requires: a custom (non-built-in) template id on a completed card,
/// and a template file written under _UserSettings/Templates.
class SuperDynamicTemplateCreatedGrader extends CodeGrader {
  SuperDynamicTemplateCreatedGrader();

  @override
  String get name => 'super_dynamic_template_created';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final completed = _completedNewCards(outcome);
    final customOnCards = _strList(outcome, _Keys.customTemplateIdsOnCards);
    final templatesCreated = _strList(outcome, _Keys.templatesCreated);

    return [
      Assertion(
        description: 'created at least one completed card',
        passed: completed.isNotEmpty,
        actual: 'completed_new_cards=${completed.length}',
        expected: '>= 1',
      ),
      Assertion(
        description: 'a custom (non-built-in) template was saved to disk',
        passed: templatesCreated.isNotEmpty,
        actual: 'templates_created=$templatesCreated',
        expected: 'non-empty',
      ),
      Assertion(
        description: 'the card renders with a custom template id',
        passed: customOnCards.isNotEmpty,
        actual: 'custom_template_ids_on_cards=$customOnCards',
        expected: 'non-empty',
      ),
    ];
  }
}

/// Verifies a TODO / reminder input was captured somewhere durable. The product
/// allows either path: a `task`-template timeline card, or a schedule pending
/// item (add_pending_item). Pass if EITHER landed.
class SuperTodoCapturedGrader extends CodeGrader {
  SuperTodoCapturedGrader();

  @override
  String get name => 'super_todo_captured';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final completed = _completedNewCards(outcome);
    final hasTaskCard = completed.any((c) =>
        (c['template_ids'] as List?)
            ?.cast<String>()
            .map((e) => e.toLowerCase())
            .contains('task') ??
        false);
    final newSchedule = _strList(outcome, _Keys.newSchedulePending);
    final hasScheduleItem = newSchedule.isNotEmpty;

    return [
      Assertion(
        description: 'todo captured as a task card OR a schedule pending item',
        passed: hasTaskCard || hasScheduleItem,
        actual: 'task_card=$hasTaskCard '
            'new_schedule_pending=$newSchedule',
        expected: 'task card with `task` template, or a new schedule item',
      ),
    ];
  }
}

/// Verifies an AMBIGUOUS / low-signal input was handled without leaving a
/// broken state. The product stance is "strong guidance, not forced", and
/// whether to ask a clarifying question vs. make a confident capture is a
/// judgment call scored qualitatively from the judgment package. This code
/// grader only enforces the deterministic floor:
///   - the run did not crash, AND
///   - it did not leave a half-built card (any new card must be `completed`
///     with a title), AND
///   - the agent did SOMETHING legible: either created a completed card, or
///     produced a non-empty reply (e.g. a clarifying question) rather than a
///     silent no-op.
class SuperAmbiguousHandledGrader extends CodeGrader {
  SuperAmbiguousHandledGrader();

  @override
  String get name => 'super_ambiguous_handled';

  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    final s = outcome.environmentState;
    final ranOk = s['ran_ok'] == true;
    final newCards = _newCards(outcome);
    final newCount = (s[_Keys.newCardCount] as int?) ?? 0;
    final completedCount = (s[_Keys.completedNewCardCount] as int?) ?? 0;

    // Any created card must be fully formed (no processing/failed placeholder
    // and no empty title).
    final halfBuilt = newCards.where((c) {
      final status = c['status'];
      final title = (c['title'] as String?)?.trim() ?? '';
      return status != 'completed' || title.isEmpty;
    }).toList();

    final toolNames = _strList(outcome, 'tool_names');
    // "Did something legible": made a completed card, or asked/answered (the
    // reply path can't be seen here, but a turn that created no card and ran
    // ok with no half-built leftovers is acceptable — the qualitative judge
    // decides if the clarifying question was the right call).
    return [
      Assertion(
        description: 'run completed without crashing',
        passed: ranOk,
        actual: 'ran_ok=$ranOk',
        expected: 'true',
      ),
      Assertion(
        description: 'no half-built card left behind',
        passed: halfBuilt.isEmpty,
        actual: newCount == 0
            ? 'no new cards'
            : 'completed=$completedCount of new=$newCount; '
                'half_built=${halfBuilt.map((c) => c['fact_id']).toList()}',
        expected: 'every new card is completed with a title',
      ),
      Assertion(
        description: 'did not call mutating tools that left no artifact',
        // A capture attempt that called save_timeline_card must have produced a
        // completed card; otherwise it half-failed.
        passed: !toolNames.contains('save_timeline_card') || completedCount >= 1,
        actual: 'tools=$toolNames completed_new=$completedCount',
        expected: 'save_timeline_card ⇒ a completed card exists',
      ),
    ];
  }
}

String _clip(String s, [int max = 80]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';