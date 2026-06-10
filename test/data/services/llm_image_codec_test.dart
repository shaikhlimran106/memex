import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/llm_image_codec.dart';

Uint8List _bytes(List<int> head) =>
    Uint8List.fromList([...head, ...List.filled(32, 0)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isLlmSafeImageBytes', () {
    test('accepts jpeg, png, gif, webp', () {
      expect(LlmImageCodec.isLlmSafeImageBytes(_bytes([0xFF, 0xD8, 0xFF])),
          isTrue);
      expect(
          LlmImageCodec.isLlmSafeImageBytes(
              _bytes([0x89, 0x50, 0x4E, 0x47])),
          isTrue);
      expect(
          LlmImageCodec.isLlmSafeImageBytes(_bytes([0x47, 0x49, 0x46, 0x38])),
          isTrue);
      expect(
        LlmImageCodec.isLlmSafeImageBytes(Uint8List.fromList([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, // RIFF....
          0x57, 0x45, 0x42, 0x50, // WEBP
        ])),
        isTrue,
      );
    });

    test('rejects heic ftyp container', () {
      final heicHead = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x34,
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x68, 0x65, 0x69, 0x63, // heic
      ]);
      expect(LlmImageCodec.isLlmSafeImageBytes(heicHead), isFalse);
    });
  });

  group('sanitizeHistoryImages', () {
    test('keeps safe images, degrades unsafe ones when transcode unavailable',
        () async {
      final pngB64 = base64Encode(_bytes([0x89, 0x50, 0x4E, 0x47]));
      final heicB64 = base64Encode(_bytes([
        0x00, 0x00, 0x00, 0x34, //
        0x66, 0x74, 0x79, 0x70, //
        0x68, 0x65, 0x69, 0x63, //
      ]));

      final state = AgentState.empty();
      state.history.messages.addAll([
        UserMessage([TextPart('safe'), ImagePart(pngB64, 'image/png')]),
        UserMessage([TextPart('poison'), ImagePart(heicB64, 'image/png')]),
        ModelMessage(textOutput: 'ok', model: 'test'),
      ]);

      // No native flutter_image_compress in tests: transcode fails and the
      // unsafe image must degrade to a text placeholder.
      final replaced = await LlmImageCodec.sanitizeHistoryImages(state);

      expect(replaced, 1);
      final safeMsg = state.history.messages[0] as UserMessage;
      expect(safeMsg.contents.whereType<ImagePart>().length, 1);

      final healedMsg = state.history.messages[1] as UserMessage;
      expect(healedMsg.contents.whereType<ImagePart>(), isEmpty);
      expect(
        healedMsg.contents.whereType<TextPart>().map((p) => p.text),
        contains(contains('format not supported')),
      );
    });
  });
}
