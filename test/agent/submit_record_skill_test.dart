import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/skills/submit_record/submit_record_skill.dart';
import 'package:memex/agent/super_agent/prompts.dart';

void main() {
  group('SubmitRecordSkill', () {
    test('exposes a single multimodal submit tool', () {
      final skill = SubmitRecordSkill();

      expect(skill.name, 'submit_record');
      expect(skill.systemPrompt, contains('controlled path'));
      expect(skill.systemPrompt, contains('image_paths'));
      expect(
          skill.systemPrompt, contains('ask whether they should be recorded'));

      final tools = skill.tools ?? const [];
      expect(tools, hasLength(1));
      expect(tools.single.name, 'submit_record');
      expect(
        tools.single.description,
        contains('normal Facts/Card/PKM pipeline'),
      );
      final properties =
          tools.single.parameters['properties'] as Map<String, dynamic>;
      expect(properties.keys, containsAll(['content', 'image_paths']));
      expect(tools.single.parameters['required'], isEmpty);
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
