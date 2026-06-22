/// A user-visible artifact produced by one agent tool call (a saved record,
/// a Timeline card, a written document, a reminder, ...), extracted from the
/// tool result metadata so the chat UI can render a preview tile.
class ChatArtifact {
  ChatArtifact({
    required this.type,
    this.id,
    this.title,
    this.snippet,
    this.path,
    this.kind,
    this.imagePaths = const [],
    this.tags = const [],
    this.updated = false,
  });

  static const String typeRecord = 'record';
  static const String typeHtmlCard = 'html_card';
  static const String typeCard = 'card';
  static const String typeFile = 'file';
  static const String typeSystemAction = 'system_action';
  static const String typeInsight = 'insight';

  final String type;

  /// Fact/card id (e.g. `2026/06/10.md#ts_3`) when the artifact is a record
  /// or Timeline card — used to deep-link into the card detail page.
  final String? id;
  final String? title;
  final String? snippet;

  /// Workspace-relative file path for [typeFile] artifacts.
  final String? path;

  /// Sub-kind for [typeSystemAction] artifacts: `calendar` or `reminder`.
  final String? kind;

  /// Workspace-relative image paths attached to a record.
  final List<String> imagePaths;
  final List<String> tags;

  /// True when an existing entity was updated rather than created.
  final bool updated;

  static const Set<String> _knownTypes = {
    typeRecord,
    typeHtmlCard,
    typeCard,
    typeFile,
    typeSystemAction,
    typeInsight,
  };

  /// Parses the `artifact` entry of a tool result metadata map. Returns null
  /// when the metadata carries no recognizable artifact.
  static ChatArtifact? fromToolMetadata(Map<String, dynamic>? metadata) {
    final raw = metadata?['artifact'];
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final type = map['type']?.toString();
    if (type == null || !_knownTypes.contains(type)) return null;

    List<String> stringList(dynamic value) {
      if (value is! List) return const [];
      return value
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList();
    }

    String? nonEmpty(dynamic value) {
      final text = value?.toString().trim();
      return (text == null || text.isEmpty) ? null : text;
    }

    return ChatArtifact(
      type: type,
      id: nonEmpty(map['id']),
      title: nonEmpty(map['title']),
      snippet: nonEmpty(map['snippet']),
      path: nonEmpty(map['path']),
      kind: nonEmpty(map['kind']),
      imagePaths: stringList(map['image_paths']),
      tags: stringList(map['tags']),
      updated: map['updated'] == true,
    );
  }
}
