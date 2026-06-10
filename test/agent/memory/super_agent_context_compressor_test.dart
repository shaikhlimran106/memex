import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/memory/super_agent_context_compressor.dart';

void main() {
  group('SuperAgentContextCompressor.stripArchivedImageBytes', () {
    test('replaces archived image parts with fs path placeholders', () {
      final episode = EpisodicMemory(
        id: 'episode_1',
        summary: '<state_snapshot/>',
        messages: [
          UserMessage(
            [
              TextPart('look at these'),
              ImagePart('AAAA', 'image/png'),
              ImagePart('BBBB', 'image/jpeg'),
            ],
            metadata: {
              'image_fs_paths': ['2026/06/a.png', '2026/06/b.jpg'],
            },
          ),
          ModelMessage(textOutput: 'nice photos', model: 'test-model'),
        ],
      );

      SuperAgentContextCompressor.stripArchivedImageBytes([episode]);

      final user = episode.messages.first as UserMessage;
      expect(user.contents.whereType<ImagePart>(), isEmpty);
      final texts =
          user.contents.whereType<TextPart>().map((part) => part.text).toList();
      expect(texts[0], 'look at these');
      expect(texts[1], contains('fs://2026/06/a.png'));
      expect(texts[2], contains('fs://2026/06/b.jpg'));
      // Non-user messages are untouched.
      expect(episode.messages.last, isA<ModelMessage>());
    });

    test('handles missing path metadata and is idempotent', () {
      final episode = EpisodicMemory(
        id: 'episode_2',
        summary: '',
        messages: [
          UserMessage([ImagePart('CCCC', 'image/png')]),
        ],
      );

      SuperAgentContextCompressor.stripArchivedImageBytes([episode]);
      SuperAgentContextCompressor.stripArchivedImageBytes([episode]);

      final user = episode.messages.first as UserMessage;
      expect(user.contents.whereType<ImagePart>(), isEmpty);
      expect(
        (user.contents.single as TextPart).text,
        '[archived image attachment]',
      );
    });
  });
}
