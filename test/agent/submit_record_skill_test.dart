import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/submit_record/submit_record_skill.dart';
import 'package:memex/agent/super_agent/prompts.dart';

void main() {
  group('SubmitRecordSkill', () {
    test('exposes a single text submit tool', () {
      final skill = SubmitRecordSkill();

      expect(skill.name, 'submit_record');
      expect(skill.systemPrompt, contains('controlled path'));
      expect(skill.systemPrompt, contains('text records only'));

      final tools = skill.tools ?? const [];
      expect(tools, hasLength(1));
      expect(tools.single.name, 'submit_record');
      expect(
        tools.single.description,
        contains('normal Facts/Card/PKM pipeline'),
      );
      expect(tools.single.parameters['required'], contains('content'));
    });
  });

  group('SuperAgent prompt', () {
    test('routes durable records through submit_record instead of file writes',
        () {
      expect(superAgentSystemPrompt, contains('Direct User Entry'));
      expect(superAgentSystemPrompt, contains('submit_record'));
      expect(
        superAgentSystemPrompt,
        contains('Do not create records by directly writing to `/Facts`'),
      );
    });
  });
}
