/// A single attachment item associated with a timeline card.
///
/// This is a pure data object — no widgets, no Flutter imports.
/// The UI layer uses [CardAttachmentFactory] to turn this into a widget.
class CardAttachmentData {
  const CardAttachmentData({
    required this.id,
    required this.type,
    required this.data,
    this.sortKey = 0,
  });

  /// Unique identity (used as widget key in the list).
  final String id;

  /// Attachment type identifier, e.g. `system_action`, `clarification_request`.
  /// Maps to a builder in [CardAttachmentFactory].
  final String type;

  /// Type-specific payload. Each builder knows how to interpret this.
  final Map<String, dynamic> data;

  /// Sort priority. Lower values appear closer to the card content.
  final int sortKey;
}
