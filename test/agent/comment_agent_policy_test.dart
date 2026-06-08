import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/agent/skills/comment_agent/comment_agent_skill.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/character_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  group('CommentAgent policy routing', () {
    late Directory tempRoot;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      tempRoot = await Directory.systemTemp.createTemp('memex_comment_policy_');
      await FileSystemService.init(tempRoot.path);
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('normal mode exposes SaveComment and SkipComment', () {
      final skill = _buildSkill(forceReply: false, tempRoot: tempRoot);
      final toolNames = _toolNames(skill);

      expect(toolNames, containsAll(['SaveComment', 'SkipComment']));
      expect(skill.systemPrompt, contains('Comment Policy'));
      expect(skill.systemPrompt, contains('SkipComment'));
      expect(skill.systemPrompt, contains('exactly one completion tool'));
    });

    test('force reply mode removes SkipComment and requires SaveComment', () {
      final skill = _buildSkill(forceReply: true, tempRoot: tempRoot);
      final toolNames = _toolNames(skill);

      expect(toolNames, contains('SaveComment'));
      expect(toolNames, isNot(contains('SkipComment')));
      expect(skill.systemPrompt, contains('must leave a visible'));
      expect(skill.systemPrompt, contains('SaveComment'));
      expect(skill.systemPrompt, isNot(contains('call `SkipComment`')));
    });

    test('counselor default persona includes a comment policy', () {
      final counselor = UserStorage.l10n.defaultCharacters.firstWhere(
        (character) =>
            character['name'] == '心理咨询师' || character['name'] == 'Counselor',
      );
      final persona = counselor['persona'] as String;

      expect(persona, contains('## Comment Policy'));
      expect(persona, contains('Reply when:'));
      expect(persona, contains('Skip when:'));
    });

    test('comment prompt supports policy based skipping in normal mode', () {
      final prompt = Prompts.commentSkillSystemPrompt(
        _policyPersona,
        'Reply in Chinese.',
      );

      expect(prompt, contains('Comment Policy'));
      expect(prompt, contains('call `SkipComment`'));
      expect(
          prompt, contains('Do not update memory when you call `SkipComment`'));
    });
  });
}

CommentAgentSkill _buildSkill({
  required bool forceReply,
  required Directory tempRoot,
}) {
  return CommentAgentSkill(
    character: CharacterModel(
      id: 'counselor',
      name: '心理咨询师',
      tags: const ['倾听'],
      persona: _policyPersona,
      enabled: true,
    ),
    factId: '2026/06/08.md#ts_1',
    workingDirectory: tempRoot.path,
    userId: 'policy_test_user',
    forceReply: forceReply,
  );
}

List<String> _toolNames(CommentAgentSkill skill) =>
    (skill.tools ?? const []).map((tool) => tool.name).toList();

const _policyPersona = '''
This is a steady listener.

## Comment Policy
Reply when:
- The user clearly expresses stress or anxiety.

Skip when:
- The entry is a neutral shopping record or schedule.
''';
