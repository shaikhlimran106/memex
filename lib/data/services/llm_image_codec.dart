import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logging/logging.dart';

final _logger = Logger('LlmImageCodec');

/// Transcodes local images into LLM-safe inline payloads.
///
/// Lifelog originals stay untouched on disk — iOS photo library exports are
/// commonly HEIC, which Gemini accepts but OpenAI-compatible endpoints (Kimi,
/// OpenAI, ...) reject ("unsupported image format"). Anything inlined as
/// base64 for a model is therefore re-encoded to JPEG, bounded to
/// [targetSize] on the long side, and auto-rotated.
class LlmImageCodec {
  static const String jpegMimeType = 'image/jpeg';

  static Future<Uint8List?> transcodeForLlm(
    String absolutePath, {
    int targetSize = 2048,
    int quality = 85,
  }) async {
    try {
      return await FlutterImageCompress.compressWithFile(
        absolutePath,
        minWidth: targetSize,
        minHeight: targetSize,
        quality: quality,
        format: CompressFormat.jpeg,
        autoCorrectionAngle: true,
        // EXIF (GPS etc.) stays on the stored original; the model never
        // needs it and omitting it shrinks the payload.
        keepExif: false,
      );
    } catch (e) {
      _logger.warning('Failed to transcode image for LLM: $absolutePath', e);
      return null;
    }
  }
}
