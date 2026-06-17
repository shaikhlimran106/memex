import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart';
import 'package:memex/agent/super_agent/subagent/super_agent_child.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 2: the generic SuperAgent child-worker runtime. These tests cover the
/// deterministic wiring (tool profile → base tools) and the run → structured
/// result extraction path, using a scripted LLM client (no live model).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SuperAgent child runtime', () {
    late AppDatabase db;
    late Directory tempRoot;
    late String userId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      AppDatabase.setTestInstance(db);
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      userId = 'child_${DateTime.now().microsecondsSinceEpoch}';
      await UserStorage.saveUser(userId);
      tempRoot = await Directory.systemTemp.createTemp('memex_child_');
      await FileSystemService.init(tempRoot.path);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
      await db.close();
    });

    SuperAgentChildConfig cfg(ChildToolProfile profile) =>
        SuperAgentChildConfig(
          childName: 'test_child',
          taskBrief: 'do the thing',
          skills: const [],
          toolProfile: profile,
        );

    test('profile none exposes no base tools', () {
      final agent = createSuperAgentChild(
        config: cfg(ChildToolProfile.none),
        client: _ScriptedClient(texts: const ['done']),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );
      expect(agent.tools ?? const [], isEmpty);
    });

    test('profile read exposes read-only base tools but no write tools', () {
      final agent = createSuperAgentChild(
        config: cfg(ChildToolProfile.read),
        client: _ScriptedClient(texts: const ['done']),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );
      final names = (agent.tools ?? const []).map((t) => t.name).toSet();
      expect(names, containsAll(<String>['LS', 'Glob', 'Grep', 'Read']));
      expect(names, isNot(contains('Write')));
      expect(names, isNot(contains('Edit')));
    });

    test('profile full adds write tools on top of read tools', () {
      final agent = createSuperAgentChild(
        config: cfg(ChildToolProfile.full),
        client: _ScriptedClient(texts: const ['done']),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );
      final names = (agent.tools ?? const []).map((t) => t.name).toSet();
      expect(names, containsAll(<String>['Read', 'Write', 'Edit']));
    });

    test('dynamic_timeline_ui gets scoped file tools injected; base stays bare',
        () {
      // Card-worker shape: no base file tools (profile none), but the
      // dynamic_timeline_ui skill should receive scoped Read/Write/Edit so
      // template editing only appears when that skill is active.
      final agent = createSuperAgentChild(
        config: SuperAgentChildConfig(
          childName: 'card_child',
          taskBrief: 'capture',
          skills: [DynamicTimelineUiSkill()],
          toolProfile: ChildToolProfile.none,
          writeRootPaths: const ['/_UserSettings/Templates'],
        ),
        client: _ScriptedClient(texts: const ['done']),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );

      // Base tools (visible without activating any skill) stay empty.
      expect(agent.tools ?? const [], isEmpty);

      // The dynamic-UI skill carries the injected scoped file tools, so they
      // appear only once the worker activates that skill.
      final uiSkill = agent.skills!
          .whereType<DynamicTimelineUiSkill>()
          .single;
      final skillToolNames = (uiSkill.tools ?? const []).map((t) => t.name).toSet();
      expect(skillToolNames, containsAll(<String>['Read', 'Write', 'Edit']));
      // Its own design tools are still present too.
      expect(skillToolNames, contains('save_timeline_template'));
    });

    test('run extracts a structured no_op result from the final message',
        () async {
      final result = await runSuperAgentChild(
        config: cfg(ChildToolProfile.read),
        client: _ScriptedClient(texts: const [
          'Nothing schedule-related here.\n\n'
              '```json\n{"status":"no_op","summary":"no dated content"}\n```',
        ]),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );
      expect(result.status, SuperAgentChildStatus.noOp);
      expect(result.summary, 'no dated content');
    });

    test('run reports failed when the child errors out', () async {
      final result = await runSuperAgentChild(
        config: cfg(ChildToolProfile.read),
        client: _ThrowingClient(),
        modelConfig: ModelConfig(model: 'test'),
        userId: userId,
      );
      expect(result.status, SuperAgentChildStatus.failed);
      expect(result.error, isNotNull);
    });
  });
}

/// Returns the i-th scripted text as a plain (no tool call) model message, so
/// the agent run ends immediately.
class _ScriptedClient extends LLMClient {
  _ScriptedClient({required this.texts});
  final List<String> texts;
  var _i = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final text = _i < texts.length ? texts[_i] : 'done';
    _i++;
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: text,
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Streaming is not used by this test client.');
  }
}

class _ThrowingClient extends LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    throw StateError('boom');
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Streaming is not used by this test client.');
  }
}
