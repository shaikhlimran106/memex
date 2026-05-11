import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/prompts.dart';

void main() {
  group('Knowledge insight language prompts', () {
    const zhInstruction =
        '**Important**: All output text must be in **zh-CN (Simplified Chinese)**.';

    test('skill prompt interpolates the configured language instruction', () {
      final prompt = Prompts.knowledgeInsightAgentKnowledgeInsightSkillPrompt(
        zhInstruction,
      );

      expect(prompt, contains(zhInstruction));
      expect(prompt, isNot(contains(r'$instruction')));
    });
  });
}
