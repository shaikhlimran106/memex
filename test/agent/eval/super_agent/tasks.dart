import 'dart:io';

import 'package:dart_agent_core/eval.dart';

import 'graders.dart';

/// Registers the SuperAgent graders so the framework's `loadEvalSuiteFromDir`
/// can resolve them from `task.json` `{"name": "...", "config": {...}}` entries.
///
/// All graders here are deterministic CODE graders. Qualitative scoring (was
/// the capture faithful? is the title good? does the PKM entry make sense? did
/// the reply actually help?) is done OUT OF BAND by reading the judgment
/// packages the harness writes to `.state_dir/.eval_judgment/` — there is no
/// LLM-as-judge inside the run.
GraderRegistry buildSuperAgentGraderRegistry() {
  final reg = GraderRegistry();

  reg.register('super_capture_complete', (_) => SuperCaptureCompleteGrader());
  reg.register('super_no_new_card', (_) => SuperNoNewCardGrader());
  reg.register(
    'super_readonly_respected',
    (_) => SuperReadOnlyRespectedGrader(),
  );
  reg.register(
    'super_template_choice',
    (cfg) => SuperTemplateChoiceGrader(
      expectedTemplateIds:
          (cfg['expected_template_ids'] as List).cast<String>(),
    ),
  );
  reg.register(
    'super_modified_card',
    (cfg) => SuperModifiedCardGrader(
      expectedFactId: cfg['expected_fact_id'] as String?,
    ),
  );
  reg.register(
    'super_dynamic_template_created',
    (_) => SuperDynamicTemplateCreatedGrader(),
  );
  reg.register('super_todo_captured', (_) => SuperTodoCapturedGrader());
  reg.register(
    'super_ambiguous_handled',
    (_) => SuperAmbiguousHandledGrader(),
  );

  return reg;
}

/// Default suite path under `test/agent/eval/super_agent/`. Resolves relative
/// to the memex repo root when `flutter test` is invoked from there.
String defaultSuperAgentSuiteDir() =>
    'test/agent/eval/super_agent/suites/capability';

/// Loads the suite from disk via the framework loader.
EvalSuite buildSuperAgentSuite({String? suiteDir}) {
  final dir = Directory(suiteDir ?? defaultSuperAgentSuiteDir());
  return loadEvalSuiteFromDir(
    dir,
    graderRegistry: buildSuperAgentGraderRegistry(),
  );
}
