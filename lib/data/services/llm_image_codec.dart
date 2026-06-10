import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_agent_core/dart_agent_core.dart';
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

  /// Whether [bytes] start with a magic number every OpenAI-compatible
  /// vision endpoint accepts (jpeg/png/gif/webp). HEIC ("....ftyp....")
  /// and anything unknown returns false.
  static bool isLlmSafeImageBytes(List<int> bytes) {
    if (bytes.length < 12) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E) return true;
    // GIF: "GIF8"
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // WEBP: "RIFF"...."WEBP"
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  /// Sniffs the leading bytes of a base64 payload without decoding all of it.
  static bool isLlmSafeBase64Image(String base64Data) {
    if (base64Data.length < 16) return false;
    try {
      final prefixLength =
          base64Data.length >= 32 ? 32 : (base64Data.length ~/ 4) * 4;
      final head = base64Decode(base64Data.substring(0, prefixLength));
      return isLlmSafeImageBytes(head);
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List?> transcodeBytesForLlm(
    Uint8List bytes, {
    int targetSize = 2048,
    int quality = 85,
  }) async {
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: targetSize,
        minHeight: targetSize,
        quality: quality,
        format: CompressFormat.jpeg,
        autoCorrectionAngle: true,
        keepExif: false,
      );
    } catch (e) {
      _logger.warning('Failed to transcode image bytes for LLM', e);
      return null;
    }
  }

  /// Heals agent session history that contains images no longer acceptable
  /// to the active provider — e.g. HEIC inlined before transcoding existed,
  /// which is replayed every turn and makes OpenAI-compatible endpoints
  /// (Kimi) fail the whole session with 400.
  ///
  /// Unsafe images are transcoded to JPEG in place; if transcoding fails they
  /// degrade to a text placeholder so the session can continue. Returns the
  /// number of replaced parts.
  static Future<int> sanitizeHistoryImages(AgentState state) async {
    var replaced = 0;
    final messages = state.history.messages;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message is! UserMessage) continue;
      if (!message.contents.any(
        (part) => part is ImagePart && !isLlmSafeBase64Image(part.base64Data),
      )) {
        continue;
      }

      final newContents = <UserContentPart>[];
      for (final part in message.contents) {
        if (part is! ImagePart || isLlmSafeBase64Image(part.base64Data)) {
          newContents.add(part);
          continue;
        }
        Uint8List? transcoded;
        try {
          transcoded =
              await transcodeBytesForLlm(base64Decode(part.base64Data));
        } catch (e) {
          _logger.warning('Failed to decode history image for sanitize', e);
        }
        if (transcoded != null) {
          newContents.add(ImagePart(base64Encode(transcoded), jpegMimeType));
        } else {
          newContents.add(TextPart(
            '[image attachment removed: format not supported by the current '
            'model provider]',
          ));
        }
        replaced += 1;
      }

      messages[i] = UserMessage(
        newContents,
        timestamp: message.timestamp,
        metadata: message.metadata,
      );
    }
    return replaced;
  }
}
