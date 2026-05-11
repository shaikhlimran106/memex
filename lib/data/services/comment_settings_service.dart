import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/logger.dart';

/// Per-user comment settings stored in `_UserSettings/comment_settings.yaml`.
///
/// Fields:
/// - `show_insight_text` (bool, default true): show insight as pinned comment
/// - `enable_character_comment` (bool, default true): auto-generate character comments
/// - `max_comment_characters` (int, default 1): max characters that comment per record
///
/// When `max_comment_characters` == 1, the original single-character selection
/// is used (keyword-based, no LLM call). When > 1, an LLM call decides which
/// characters participate.
class CommentSettings {
  final bool showInsightText;
  final bool enableCharacterComment;
  final int maxCommentCharacters;

  const CommentSettings({
    this.showInsightText = true,
    this.enableCharacterComment = true,
    this.maxCommentCharacters = 1,
  });

  factory CommentSettings.fromYaml(Map yaml) {
    return CommentSettings(
      showInsightText: yaml['show_insight_text'] as bool? ?? true,
      enableCharacterComment: yaml['enable_character_comment'] as bool? ?? true,
      maxCommentCharacters: yaml['max_comment_characters'] as int? ?? 1,
    );
  }

  String toYaml() {
    return 'show_insight_text: $showInsightText\n'
        'enable_character_comment: $enableCharacterComment\n'
        'max_comment_characters: $maxCommentCharacters\n';
  }

  CommentSettings copyWith({
    bool? showInsightText,
    bool? enableCharacterComment,
    int? maxCommentCharacters,
  }) {
    return CommentSettings(
      showInsightText: showInsightText ?? this.showInsightText,
      enableCharacterComment:
          enableCharacterComment ?? this.enableCharacterComment,
      maxCommentCharacters: maxCommentCharacters ?? this.maxCommentCharacters,
    );
  }
}

/// Service for reading/writing per-user comment settings.
/// Path is defined in [FileSystemService.getCommentSettingsPath].
class CommentSettingsService {
  static final _logger = getLogger('CommentSettingsService');

  /// Load comment settings for a user. Returns defaults if file doesn't exist.
  static Future<CommentSettings> load(String userId) async {
    try {
      final filePath =
          FileSystemService.instance.getCommentSettingsPath(userId);
      final file = File(filePath);
      if (!await file.exists()) return const CommentSettings();

      final content = await file.readAsString();
      if (content.trim().isEmpty) return const CommentSettings();

      final yaml = loadYaml(content);
      if (yaml is YamlMap) {
        return CommentSettings.fromYaml(yaml);
      }
      return const CommentSettings();
    } catch (e) {
      _logger.warning('Failed to load comment settings: $e');
      return const CommentSettings();
    }
  }

  /// Save comment settings for a user.
  static Future<void> save(String userId, CommentSettings settings) async {
    try {
      final filePath =
          FileSystemService.instance.getCommentSettingsPath(userId);
      final dir = Directory(path.dirname(filePath));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await File(filePath).writeAsString(settings.toYaml());
    } catch (e) {
      _logger.warning('Failed to save comment settings: $e');
    }
  }
}
