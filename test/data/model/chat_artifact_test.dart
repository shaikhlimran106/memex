import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/model/chat_artifact.dart';

void main() {
  group('ChatArtifact.fromToolMetadata', () {
    test('parses a record artifact with images', () {
      final artifact = ChatArtifact.fromToolMetadata({
        'artifact': {
          'type': 'record',
          'id': '2026/06/10.md#ts_3',
          'snippet': '今天跑了 5 公里',
          'image_paths': ['assets/a.jpg', 'assets/b.jpg'],
        },
      });

      expect(artifact, isNotNull);
      expect(artifact!.type, ChatArtifact.typeRecord);
      expect(artifact.id, '2026/06/10.md#ts_3');
      expect(artifact.snippet, '今天跑了 5 公里');
      expect(artifact.imagePaths, ['assets/a.jpg', 'assets/b.jpg']);
      expect(artifact.updated, isFalse);
    });

    test('parses an html card artifact with tags and updated flag', () {
      final artifact = ChatArtifact.fromToolMetadata({
        'artifact': {
          'type': 'html_card',
          'id': '2026/06/09.md#ts_1',
          'title': '本周进度',
          'tags': ['Project', 'Milestone'],
          'updated': true,
        },
      });

      expect(artifact, isNotNull);
      expect(artifact!.type, ChatArtifact.typeHtmlCard);
      expect(artifact.title, '本周进度');
      expect(artifact.tags, ['Project', 'Milestone']);
      expect(artifact.updated, isTrue);
    });

    test('parses a file artifact', () {
      final artifact = ChatArtifact.fromToolMetadata({
        'artifact': {
          'type': 'file',
          'path': 'PKM/Projects/memex.md',
          'snippet': '# Memex',
          'updated': false,
        },
      });

      expect(artifact, isNotNull);
      expect(artifact!.type, ChatArtifact.typeFile);
      expect(artifact.path, 'PKM/Projects/memex.md');
    });

    test('returns null for missing, malformed, or unknown artifacts', () {
      expect(ChatArtifact.fromToolMetadata(null), isNull);
      expect(ChatArtifact.fromToolMetadata({}), isNull);
      expect(ChatArtifact.fromToolMetadata({'artifact': 'oops'}), isNull);
      expect(
        ChatArtifact.fromToolMetadata({
          'artifact': {'type': 'alien'},
        }),
        isNull,
      );
      expect(
        ChatArtifact.fromToolMetadata({
          'artifact': {'id': 'x'},
        }),
        isNull,
      );
    });

    test('normalizes empty strings to null and skips empty list entries', () {
      final artifact = ChatArtifact.fromToolMetadata({
        'artifact': {
          'type': 'system_action',
          'kind': 'reminder',
          'title': '晚间复盘',
          'snippet': '',
          'image_paths': ['', 'assets/x.png'],
        },
      });

      expect(artifact, isNotNull);
      expect(artifact!.kind, 'reminder');
      expect(artifact.snippet, isNull);
      expect(artifact.imagePaths, ['assets/x.png']);
    });
  });
}
