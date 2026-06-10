import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';
import 'package:memex/agent/run_mode/agent_action_approval_service.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/agent/skills/dynamic_timeline_ui/design_pattern_library.dart';

final _logger = Logger('DynamicTimelineUiSkill');

/// Skill for creating display-only dynamic HTML cards on the Timeline.
class DynamicTimelineUiSkill extends Skill {
  DynamicTimelineUiSkill()
      : super(
          name: 'dynamic_timeline_ui',
          description:
              'Creates or updates custom visual Timeline cards using safe, self-contained HTML. '
              'Use when the user asks Memex to generate a visual UI/card/view on the Timeline, '
              'preview a custom interface, or adjust the visual style of an existing Timeline card. '
              'Do not use this for ordinary recording; use manage_timeline_card instead.',
          systemPrompt: _buildSystemPrompt(),
          tools: _buildTools(),
        );

  static String _buildSystemPrompt() {
    return '''
# Dynamic Timeline UI Skill

Use this skill when the user explicitly wants a custom visual card, timeline UI, mini dashboard, generated view, or a style/layout change that should appear on the Memex Timeline.

This is an MVP display pipeline:
- Generate self-contained HTML/CSS only.
- Do not include JavaScript, iframes, forms, network calls, external scripts, external stylesheets, or event handler attributes.
- Keep the card compact and mobile-first. It will be rendered inside a Timeline WebView card.
- Prefer a single root container, inline CSS, readable text, and responsive dimensions.
- The result is display-only for now. If the user asks for actual system actions, use the appropriate action/tool skill instead of faking controls in HTML.
- Before generating HTML, call `recommend_dynamic_timeline_design_patterns` or `get_dynamic_timeline_design_pattern` unless the user explicitly provides a complete design direction.
- Treat design patterns as reference material, not rigid templates. Adapt the HTML to the user content and constraints.

Use `create_dynamic_timeline_card` when there is no existing card id.
Use `update_dynamic_timeline_card` when the user asks to revise a specific existing card.
''';
  }

  static List<Tool> _buildTools() {
    return [
      Tool(
        name: 'recommend_dynamic_timeline_design_patterns',
        description:
            'Recommend visual design patterns for a dynamic Timeline UI request based on user intent, content, and constraints.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'intent': {
              'type': 'string',
              'description':
                  'What the user wants to do, for example "record two photos", "review a project", or "compare options".',
            },
            'content_summary': {
              'type': 'string',
              'description':
                  'Short summary of the source content or user data that will drive the UI.',
            },
            'constraints': {
              'type': 'string',
              'description':
                  'User style constraints or feedback, for example "more editorial", "less text", "dashboard", "warmer".',
            },
            'limit': {
              'type': 'integer',
              'description': 'Number of candidates to return. Defaults to 3.',
            },
          },
          'required': ['intent'],
        },
        executable: (Map<String, dynamic> args) {
          return DynamicTimelineDesignPatternLibrary.recommendationJson(
            intent: args['intent']?.toString() ?? '',
            contentSummary: args['content_summary']?.toString(),
            constraints: args['constraints']?.toString(),
            limit: (args['limit'] as num?)?.toInt() ?? 3,
          );
        },
      ),
      Tool(
        name: 'get_dynamic_timeline_design_pattern',
        description:
            'Get the full design rules and HTML reference example for a dynamic Timeline UI pattern.',
        parameters: {
          'type': 'object',
          'properties': {
            'pattern_id': {
              'type': 'string',
              'description':
                  'Design pattern id returned by recommend_dynamic_timeline_design_patterns.',
            },
          },
          'required': ['pattern_id'],
        },
        executable: (String patternId) {
          return DynamicTimelineDesignPatternLibrary.patternJson(patternId);
        },
      ),
      Tool(
        name: 'list_dynamic_timeline_design_patterns',
        description:
            'List all available dynamic Timeline UI design pattern summaries.',
        parameters: {
          'type': 'object',
          'properties': {},
        },
        executable: () {
          return DynamicTimelineDesignPatternLibrary.catalogJson();
        },
      ),
      Tool(
        name: 'create_dynamic_timeline_card',
        description:
            'Create a new display-only dynamic HTML card and show it on the Timeline.',
        parameters: {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'Short card title for Timeline and detail pages.',
            },
            'html': {
              'type': 'string',
              'description':
                  'Self-contained HTML/CSS fragment or document. Scripts, iframes, external resources, forms, and event handler attributes are not allowed.',
            },
            'description': {
              'type': 'string',
              'description':
                  'Plain-text reason or source note to store as the underlying Markdown fact. If omitted, a short generated note is used.',
            },
            'content_creation_date': {
              'type': 'string',
              'description':
                  'Optional local creation date, for example "2026-06-09 20:30:00". Defaults to now.',
            },
            'tags': {
              'type': 'array',
              'description':
                  'Optional 1-3 existing internal Timeline tag names.',
              'items': {
                'type': 'string',
                'enum': [
                  'Project',
                  'Trip',
                  'Milestone',
                  'Health',
                  'Relationship',
                  'Finance',
                  'Knowledge',
                  'Emotion',
                  'Visual',
                  'Audio',
                ],
              },
            },
            'design_pattern_id': {
              'type': 'string',
              'description':
                  'Optional pattern id used as the visual reference. Prefer ids returned by recommend_dynamic_timeline_design_patterns.',
            },
            'design_notes': {
              'type': 'string',
              'description':
                  'Short note explaining how the selected design pattern was adapted.',
            },
          },
          'required': ['title', 'html'],
        },
        executable: (
          String title,
          String html,
          String? description,
          String? contentCreationDate,
          dynamic tags,
          String? designPatternId,
          String? designNotes,
        ) =>
            _createDynamicTimelineCard(
          title: title,
          html: html,
          description: description,
          contentCreationDate: contentCreationDate,
          tags: tags,
          designPatternId: designPatternId,
          designNotes: designNotes,
        ),
      ),
      Tool(
        name: 'update_dynamic_timeline_card',
        description:
            'Update the HTML, title, or tags of an existing dynamic Timeline card.',
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Existing Timeline card id, for example "2026/06/09.md#ts_3".',
            },
            'title': {
              'type': 'string',
              'description': 'Optional replacement card title.',
            },
            'html': {
              'type': 'string',
              'description':
                  'Optional replacement self-contained HTML/CSS. Scripts, iframes, external resources, forms, and event handler attributes are not allowed.',
            },
            'tags': {
              'type': 'array',
              'description':
                  'Optional replacement 1-3 existing internal Timeline tag names.',
              'items': {
                'type': 'string',
                'enum': [
                  'Project',
                  'Trip',
                  'Milestone',
                  'Health',
                  'Relationship',
                  'Finance',
                  'Knowledge',
                  'Emotion',
                  'Visual',
                  'Audio',
                ],
              },
            },
            'design_pattern_id': {
              'type': 'string',
              'description':
                  'Optional replacement pattern id used as the visual reference.',
            },
            'design_notes': {
              'type': 'string',
              'description':
                  'Optional note explaining the design update or user feedback applied.',
            },
          },
          'required': ['card_id'],
        },
        executable: (
          String cardId,
          String? title,
          String? html,
          dynamic tags,
          String? designPatternId,
          String? designNotes,
        ) =>
            _updateDynamicTimelineCard(
          cardId: cardId,
          title: title,
          html: html,
          tags: tags,
          designPatternId: designPatternId,
          designNotes: designNotes,
        ),
      ),
    ];
  }

  static Future<AgentToolResult> _createDynamicTimelineCard({
    required String title,
    required String html,
    String? description,
    String? contentCreationDate,
    dynamic tags,
    String? designPatternId,
    String? designNotes,
  }) async {
    final denied = await gateMutatingToolCall(
      toolName: 'create_dynamic_timeline_card',
      summary: title,
    );
    if (denied != null) return denied;

    final cardData = await createDynamicTimelineCardForUser(
      userId: _currentUserId(),
      title: title,
      html: html,
      description: description,
      contentCreationDate: contentCreationDate,
      tags: tags,
      designPatternId: designPatternId,
      designNotes: designNotes,
    );

    return AgentToolResult(
      content: TextPart(
        'Created dynamic Timeline card "${cardData.title}" with id ${cardData.factId}.',
      ),
      metadata: {
        'artifact': {
          'type': 'html_card',
          'id': cardData.factId,
          'title': cardData.title,
          'tags': cardData.tags,
          'updated': false,
        },
      },
    );
  }

  static Future<CardData> createDynamicTimelineCardForUser({
    required String userId,
    required String title,
    required String html,
    String? description,
    String? contentCreationDate,
    dynamic tags,
    String? designPatternId,
    String? designNotes,
  }) async {
    final fileService = FileSystemService.instance;
    final createdAt = _parseContentCreationDate(contentCreationDate);
    final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;
    final cleanTitle = _validateTitle(title);
    final cleanHtml = sanitizeHtmlForTimeline(html);
    final tagNames = normalizeTimelineTags(tags);
    final cleanDesignPatternId = _normalizeDesignPatternId(designPatternId);
    final cleanDesignNotes = _normalizeOptionalText(designNotes);

    final factId = await fileService.generateFactId(userId, createdAt);
    final simpleFactId = fileService.extractSimpleFactId(factId);
    final timeStr = fileService.formatTime(createdAt);
    final factText = _buildFactText(cleanTitle, description);
    final markdownEntry = '## <id:$simpleFactId> $timeStr "{}"\n\n$factText\n';

    await fileService.appendToDailyFactFile(userId, createdAt, markdownEntry);

    final uiConfigs = [
      UiConfig(
        templateId: 'legacy_html',
        data: _buildLegacyHtmlData(
          html: cleanHtml,
          designPatternId: cleanDesignPatternId,
          designNotes: cleanDesignNotes,
        ),
      ),
    ];
    final cardData = CardData(
      factId: factId,
      timestamp: timestamp,
      status: 'completed',
      tags: tagNames,
      title: cleanTitle,
      uiConfigs: uiConfigs,
    );

    final success =
        await fileService.safeWriteCardFile(userId, factId, cardData);
    if (!success) {
      throw StateError('Failed to write dynamic timeline card: $factId');
    }

    _emitCardAdded(cardData);
    unawaited(_logCreateEvent(fileService, userId, factId, cleanTitle));

    return cardData;
  }

  static Future<AgentToolResult> _updateDynamicTimelineCard({
    required String cardId,
    String? title,
    String? html,
    dynamic tags,
    String? designPatternId,
    String? designNotes,
  }) async {
    final userId = _currentUserId();
    final fileService = FileSystemService.instance;
    final cleanCardId = cardId.trim();
    if (cleanCardId.isEmpty) {
      throw ArgumentError('card_id is required');
    }

    final denied = await gateMutatingToolCall(
      toolName: 'update_dynamic_timeline_card',
      summary: title?.trim().isNotEmpty == true
          ? '${title!.trim()} ($cleanCardId)'
          : cleanCardId,
    );
    if (denied != null) return denied;

    final cleanTitle =
        title == null || title.trim().isEmpty ? null : _validateTitle(title);
    final cleanHtml = html == null || html.trim().isEmpty
        ? null
        : sanitizeHtmlForTimeline(html);
    final tagNames = tags == null ? null : normalizeTimelineTags(tags);
    final cleanDesignPatternId = _normalizeDesignPatternId(designPatternId);
    final cleanDesignNotes = _normalizeOptionalText(designNotes);

    if (cleanTitle == null &&
        cleanHtml == null &&
        tagNames == null &&
        cleanDesignPatternId == null &&
        cleanDesignNotes == null) {
      throw ArgumentError(
        'Provide at least one of title, html, tags, design_pattern_id, or design_notes.',
      );
    }

    final updatedCard = await fileService.updateCardFile(
      userId,
      cleanCardId,
      (card) {
        var uiConfigs = card.uiConfigs;
        if (cleanHtml != null ||
            cleanDesignPatternId != null ||
            cleanDesignNotes != null) {
          uiConfigs = _upsertLegacyHtmlConfig(
            card.uiConfigs,
            html: cleanHtml,
            designPatternId: cleanDesignPatternId,
            designNotes: cleanDesignNotes,
          );
        }
        return card.copyWith(
          status: 'completed',
          title: cleanTitle ?? card.title,
          uiConfigs: uiConfigs,
          tags: tagNames ?? card.tags,
          clearFailureReason: true,
        );
      },
    );

    if (updatedCard == null) {
      throw ArgumentError('Timeline card not found: $cleanCardId');
    }

    _emitCardUpdated(updatedCard);

    return AgentToolResult(
      content: TextPart('Updated dynamic Timeline card $cleanCardId.'),
      metadata: {
        'artifact': {
          'type': 'html_card',
          'id': cleanCardId,
          'title': updatedCard.title,
          'tags': updatedCard.tags,
          'updated': true,
        },
      },
    );
  }

  static String sanitizeHtmlForTimeline(String value) {
    var html = value.trim();
    if (html.startsWith('```')) {
      html = html
          .replaceFirst(RegExp(r'^```(?:html)?\s*', caseSensitive: false), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    if (html.isEmpty) {
      throw ArgumentError('html is required');
    }
    if (html.length > 60000) {
      throw ArgumentError('html is too large for a Timeline card.');
    }

    final lower = html.toLowerCase();
    const blockedNeedles = [
      '<script',
      '</script',
      '<iframe',
      '<object',
      '<embed',
      '<form',
      '<input',
      '<button',
      '<link',
      '<meta',
      'javascript:',
      'data:text/html',
      'srcdoc=',
    ];
    for (final needle in blockedNeedles) {
      if (lower.contains(needle)) {
        throw ArgumentError('html contains unsupported content: $needle');
      }
    }

    final eventAttributePattern =
        RegExp(r'\son[a-z]+\s*=', caseSensitive: false);
    if (eventAttributePattern.hasMatch(html)) {
      throw ArgumentError('html event handler attributes are not supported.');
    }

    return html;
  }

  static List<String> normalizeTimelineTags(dynamic value) {
    if (value == null) return const [];

    final rawList = _normalizeListArgument(value, 'tags');
    final tags = <String>[];
    for (final item in rawList) {
      final raw = item is Map ? item['name'] : item;
      if (raw == null) continue;
      var name = raw.toString().trim();
      if (name.isEmpty) continue;
      name = name[0].toUpperCase() + name.substring(1).toLowerCase();
      final canonical = _canonicalTags[name.toLowerCase()];
      if (canonical == null) {
        throw ArgumentError(
          "Invalid tag '$name'. Allowed tags: ${_canonicalTags.values.join(', ')}.",
        );
      }
      if (!tags.contains(canonical)) {
        tags.add(canonical);
      }
      if (tags.length == 3) break;
    }
    return tags;
  }

  static const Map<String, String> _canonicalTags = {
    'project': 'Project',
    'trip': 'Trip',
    'milestone': 'Milestone',
    'health': 'Health',
    'relationship': 'Relationship',
    'finance': 'Finance',
    'knowledge': 'Knowledge',
    'emotion': 'Emotion',
    'visual': 'Visual',
    'audio': 'Audio',
  };

  static List<UiConfig> _upsertLegacyHtmlConfig(
    List<UiConfig> existing, {
    String? html,
    String? designPatternId,
    String? designNotes,
  }) {
    final next = <UiConfig>[];
    var replaced = false;
    for (final config in existing) {
      if (config.templateId == 'legacy_html') {
        if (!replaced) {
          final mergedData = Map<String, dynamic>.from(config.data);
          if (html != null) {
            mergedData['html'] = html;
          }
          if (designPatternId != null) {
            mergedData['design_pattern_id'] = designPatternId;
          }
          if (designNotes != null) {
            mergedData['design_notes'] = designNotes;
          }
          if ((mergedData['html'] as String?)?.trim().isEmpty != false) {
            throw ArgumentError(
              'Existing dynamic card has no html; provide html to update it.',
            );
          }
          next.add(UiConfig(templateId: 'legacy_html', data: mergedData));
          replaced = true;
        }
        continue;
      }
      next.add(config);
    }
    if (!replaced) {
      if (html == null) {
        throw ArgumentError(
          'Card has no dynamic html config; provide html to create one.',
        );
      }
      next.insert(
        0,
        UiConfig(
          templateId: 'legacy_html',
          data: _buildLegacyHtmlData(
            html: html,
            designPatternId: designPatternId,
            designNotes: designNotes,
          ),
        ),
      );
    }
    return next;
  }

  static Map<String, dynamic> _buildLegacyHtmlData({
    required String html,
    String? designPatternId,
    String? designNotes,
  }) {
    return {
      'html': html,
      if (designPatternId != null) 'design_pattern_id': designPatternId,
      if (designNotes != null) 'design_notes': designNotes,
    };
  }

  static String? _normalizeDesignPatternId(String? value) {
    final cleanValue = value?.trim();
    if (cleanValue == null || cleanValue.isEmpty) {
      return null;
    }
    DynamicTimelineDesignPatternLibrary.requireById(cleanValue);
    return cleanValue;
  }

  static String? _normalizeOptionalText(String? value) {
    final cleanValue = value?.trim();
    if (cleanValue == null || cleanValue.isEmpty) {
      return null;
    }
    return cleanValue.length > 240 ? cleanValue.substring(0, 240) : cleanValue;
  }

  static String _currentUserId() {
    final context = AgentCallToolContext.current;
    if (context == null) {
      throw StateError(
        'Dynamic timeline UI tools must run inside an agent execution context.',
      );
    }
    final userId = context.state.metadata['userId']?.toString();
    if (userId == null || userId.isEmpty) {
      throw StateError('Agent state metadata does not include userId.');
    }
    return userId;
  }

  static DateTime _parseContentCreationDate(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return DateTime.now();
    }
    try {
      return DateTime.parse(trimmed);
    } catch (_) {
      throw ArgumentError(
        'content_creation_date must be parseable, for example "2026-06-09 20:30:00".',
      );
    }
  }

  static String _validateTitle(String title) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw ArgumentError('title is required');
    }
    if (cleanTitle.length > 80) {
      throw ArgumentError('title must be 80 characters or fewer.');
    }
    return cleanTitle;
  }

  static String _buildFactText(String title, String? description) {
    final text = description?.trim();
    if (text != null && text.isNotEmpty) {
      return text;
    }
    return 'Agent generated a dynamic Timeline UI card: $title';
  }

  static List<dynamic> _normalizeListArgument(dynamic value, String name) {
    if (value is List) {
      return value;
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return const [];
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded;
        }
      } on FormatException catch (e) {
        throw ArgumentError('$name must be valid JSON when passed as a string: '
            '${e.message}');
      }
    }
    throw ArgumentError(
      '$name must be an array or a JSON-encoded array string, got ${value.runtimeType}.',
    );
  }

  static void _emitCardAdded(CardData card) {
    EventBusService.instance.emitEvent(
      CardAddedMessage(
        id: card.factId,
        html: '',
        timestamp: card.timestamp,
        tags: card.tags,
        status: card.status,
        title: card.title,
        uiConfigs: card.uiConfigs,
      ),
    );
  }

  static void _emitCardUpdated(CardData card) {
    EventBusService.instance.emitEvent(
      CardUpdatedMessage(
        id: card.factId,
        html: '',
        timestamp: card.timestamp,
        tags: card.tags,
        status: card.status,
        title: card.title,
        uiConfigs: card.uiConfigs,
      ),
    );
  }

  static Future<void> _logCreateEvent(
    FileSystemService fileService,
    String userId,
    String factId,
    String title,
  ) async {
    try {
      final parts = factId.split('#');
      if (parts.length != 2) return;
      final dateWithoutExt = parts[0].replaceFirst('.md', '');
      final cardPath = 'Cards/${dateWithoutExt}_${parts[1]}.yaml';
      await fileService.eventLogService.logFileModified(
        userId: userId,
        filePath: cardPath,
        description: 'Agent created dynamic timeline UI card',
        metadata: {'fact_id': factId, 'title': title},
      );
    } catch (e) {
      _logger.warning('Failed to log dynamic timeline UI card creation: $e');
    }
  }
}
