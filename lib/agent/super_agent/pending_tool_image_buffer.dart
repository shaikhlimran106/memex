import 'package:dart_agent_core/dart_agent_core.dart';

/// In-memory, per-session relay for images that a tool wants the model to
/// "see".
///
/// Why this exists: OpenAI-compatible providers reject images inside a tool
/// (function) result message — only text is allowed there. But a `UserMessage`
/// carrying an `ImagePart` is accepted by every provider (OpenAI, Gemini,
/// Claude). So instead of returning the image in the tool result, a tool stores
/// it here, returns text only, and the SuperAgent `systemCallback` drains it on
/// the next LLM call and injects it as a `UserMessage`.
///
/// The buffer is pure memory and is never persisted. Drained images are sent to
/// the model exactly once (on the immediately following call) and are not added
/// to `state.history`, so they do not bloat the agent state file.
class PendingToolImage {
  const PendingToolImage({
    required this.message,
    required this.image,
  });

  final String message;
  final ImagePart image;
}

class PendingToolImageBuffer {
  PendingToolImageBuffer._();

  static final PendingToolImageBuffer instance = PendingToolImageBuffer._();

  final Map<String, List<PendingToolImage>> _bySession = {};

  /// Queue an image for [sessionId] to be injected on the next LLM call.
  void add(
    String sessionId,
    ImagePart image, {
    required String message,
  }) {
    if (sessionId.isEmpty) return;
    (_bySession[sessionId] ??= <PendingToolImage>[]).add(
      PendingToolImage(message: message, image: image),
    );
  }

  /// Take and clear all pending images for [sessionId] (one-shot).
  List<PendingToolImage> drain(String sessionId) {
    final images = _bySession.remove(sessionId);
    if (images == null || images.isEmpty) return const [];
    return images;
  }
}
