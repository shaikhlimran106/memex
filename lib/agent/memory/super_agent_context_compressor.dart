import 'package:dart_agent_core/dart_agent_core.dart';

/// Context compressor for the SuperAgent chat entry.
///
/// Wraps the core [LLMBasedContextCompressor] (Claude Code-style fixed-quota
/// compaction: summarize old messages into a snapshot once the prompt exceeds
/// the quota, keep the most recent messages verbatim — quota unchanged from
/// the core default) and adds one Memex-specific cleanup: once messages are
/// archived into episodic memory, their inline image base64 payloads are
/// replaced with `fs://` path placeholders.
///
/// Rationale: `retrieve_memory` can only return archived messages as text, so
/// archived image bytes are dead weight — they can never reach the model again
/// but would otherwise be rewritten into the agent state file on every save.
/// Live (un-compacted) history is left untouched: images stay fully visible
/// to the model until compaction.
class SuperAgentContextCompressor implements ContextCompressor {
  SuperAgentContextCompressor({
    required LLMClient client,
    required ModelConfig modelConfig,
    int totalTokenThreshold = 64000,
    int keepRecentMessageSize = 10,
  }) : _inner = LLMBasedContextCompressor(
          client: client,
          modelConfig: modelConfig,
          totalTokenThreshold: totalTokenThreshold,
          keepRecentMessageSize: keepRecentMessageSize,
        );

  final LLMBasedContextCompressor _inner;

  @override
  Future compress(AgentState state) async {
    await _inner.compress(state);
    stripArchivedImageBytes(state.history.episodicMemories);
  }

  /// Replaces every [ImagePart] in archived episodic messages with a
  /// [TextPart] placeholder. Uses the `image_fs_paths` metadata tag written
  /// by ChatService at send time to keep the file reference. Idempotent.
  static void stripArchivedImageBytes(List<EpisodicMemory> episodes) {
    for (final episode in episodes) {
      for (var i = 0; i < episode.messages.length; i++) {
        final message = episode.messages[i];
        if (message is! UserMessage) continue;
        if (!message.contents.any((part) => part is ImagePart)) continue;

        final fsPaths = (message.metadata?['image_fs_paths'] as List?)
                ?.map((path) => path.toString())
                .toList() ??
            const <String>[];

        var imageIndex = 0;
        final newContents = <UserContentPart>[];
        for (final part in message.contents) {
          if (part is ImagePart) {
            final path =
                imageIndex < fsPaths.length ? fsPaths[imageIndex] : null;
            imageIndex += 1;
            newContents.add(TextPart(
              path != null
                  ? '[archived image attachment: fs://$path]'
                  : '[archived image attachment]',
            ));
          } else {
            newContents.add(part);
          }
        }

        episode.messages[i] = UserMessage(
          newContents,
          timestamp: message.timestamp,
          metadata: message.metadata,
        );
      }
    }
  }
}
