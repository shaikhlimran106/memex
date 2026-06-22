import 'dart:typed_data';

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
          LlmImageCodec.isLlmSafeImageBytes(_bytes([0x89, 0x50, 0x4E, 0x47])),
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
}
