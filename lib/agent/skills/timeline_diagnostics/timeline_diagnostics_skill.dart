import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/data/repositories/retry_failed_cards.dart'
    as retry_failed_cards_endpoint;
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as path;

final _logger = getLogger('TimelineDiagnosticsSkill');

/// Read-only Timeline/Card diagnostics for Super Agent.
///
/// These tools inspect local card/fact data and asset references. They do not
/// claim to verify the live phone screen; visual confirmation still requires a
/// screenshot or user feedback.
class TimelineDiagnosticsSkill extends Skill {
  TimelineDiagnosticsSkill()
      : super(
          name: 'timeline_diagnostics',
          description:
              'Diagnoses Memex Timeline cards, image attachments, card render paths, and failed card generation. '
              'Use when the user reports that a Timeline card, image, HTML UI, or card processing result is missing, wrong, ugly, stuck, or failed. '
              'This skill can inspect local card/fact data and retry failed card generation, but it cannot see the current phone screen.',
          systemPrompt: _buildSystemPrompt(),
          tools: _buildTools(),
        );

  static String _buildSystemPrompt() {
    return '''
# Timeline Diagnostics Skill

Use this skill before making claims about Timeline/card rendering problems, missing images, stuck cards, failed cards, or HTML/dynamic UI cards.

Important limits:
- These tools inspect local data files and known render rules. They cannot see the user's live phone screen.
- Do not say a visual issue is fixed unless a concrete write/retry tool succeeded, and still say the user must visually confirm it in the app.
- If the user provided a screenshot, combine the screenshot observation with these diagnostics.
- Keep the diagnostic path bounded. For a known card id, use `inspect_timeline_card` plus `inspect_timeline_card_assets`, and only add `describe_timeline_render_path` if the render mode is still unclear.
- After one bounded diagnostic pass, summarize the result and stop searching. Do not chain generic file tools after these diagnostics unless the user explicitly asks for developer/source-code debugging.
- For vague follow-ups without a clear target, use `list_recent_timeline_cards` once or ask for the screenshot/exact card id. Do not search unrelated Cards, PKM, `_UserSettings`, or DynamicSurface files.

How to report results:
- Checked: data inspected, no write performed.
- Requeued: a failed card was submitted back to the normal processing pipeline.
- Needs visual confirmation: the data looks correct but the live UI still needs user/screenshot confirmation.
''';
  }

  static List<Tool> _buildTools() {
    return [
      Tool(
        name: 'list_recent_timeline_cards',
        description:
            'List recent Timeline card records with status, templates, fact presence, and asset-reference counts.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'description':
                  'Maximum number of recent cards to inspect. Defaults to 10, max 30.',
            },
          },
        },
        executable: (Map<String, dynamic> args) async {
          final userId = await _resolveUserId();
          final limit = _intArg(args['limit'], fallback: 10, min: 1, max: 30);
          return _json(await listRecentTimelineCardsForUser(
            userId: userId,
            limit: limit,
          ));
        },
      ),
      Tool(
        name: 'inspect_timeline_card',
        description:
            'Inspect one Timeline card by card_id/fact_id, including card YAML, fact content, UI configs, render path, and likely data issues.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Timeline card id / fact id, for example 2026/06/10.md#ts_3.',
            },
          },
          'required': ['card_id'],
        },
        executable: (Map<String, dynamic> args) async {
          final userId = await _resolveUserId();
          final cardId = _requiredString(args, 'card_id');
          return _json(await inspectTimelineCardForUser(
            userId: userId,
            cardId: cardId,
          ));
        },
      ),
      Tool(
        name: 'inspect_timeline_card_assets',
        description:
            'Inspect fs:// image/audio references for a Timeline card and check whether local asset, analysis, and OCR files exist.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Timeline card id / fact id, for example 2026/06/10.md#ts_3.',
            },
          },
          'required': ['card_id'],
        },
        executable: (Map<String, dynamic> args) async {
          final userId = await _resolveUserId();
          final cardId = _requiredString(args, 'card_id');
          return _json(await inspectTimelineCardAssetsForUser(
            userId: userId,
            cardId: cardId,
          ));
        },
      ),
      Tool(
        name: 'describe_timeline_render_path',
        description:
            'Describe how the current Timeline implementation will render a card from its UI config and assets.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Timeline card id / fact id, for example 2026/06/10.md#ts_3.',
            },
          },
          'required': ['card_id'],
        },
        executable: (Map<String, dynamic> args) async {
          final userId = await _resolveUserId();
          final cardId = _requiredString(args, 'card_id');
          return _json(await describeTimelineRenderPathForUser(
            userId: userId,
            cardId: cardId,
          ));
        },
      ),
      Tool(
        name: 'retry_failed_timeline_card',
        description:
            'Retry generation for a failed Timeline card through the normal local processing pipeline. Only works for cards whose status is failed.',
        parameterMode: ToolParameterMode.object,
        parameters: {
          'type': 'object',
          'properties': {
            'card_id': {
              'type': 'string',
              'description':
                  'Timeline card id / fact id, for example 2026/06/10.md#ts_3.',
            },
          },
          'required': ['card_id'],
        },
        executable: (Map<String, dynamic> args) async {
          final cardId = _requiredString(args, 'card_id');
          final retried =
              await retry_failed_cards_endpoint.retryFailedCardGeneration(
            cardId,
          );
          return _json({
            'kind': 'retry_failed_timeline_card',
            'card_id': cardId,
            'requeued': retried,
            'message': retried
                ? 'Requeued the failed card through the normal processing pipeline. This does not visually verify the phone screen.'
                : 'Card was not requeued. It may be missing or not currently marked failed.',
            'can_verify_current_screen': false,
          });
        },
      ),
    ];
  }

  static Future<Map<String, dynamic>> listRecentTimelineCardsForUser({
    required String userId,
    int limit = 10,
  }) async {
    final fs = FileSystemService.instance;
    final safeLimit = limit.clamp(1, 30);
    final cardFiles = await fs.listAllCardFiles(userId);
    final summaries = <Map<String, dynamic>>[];

    for (final cardFile in cardFiles.take(safeLimit)) {
      final cardId = fs.factIdFromCardPath(cardFile);
      if (cardId == null) continue;

      final card = await fs.readCardFile(userId, cardId);
      if (card == null || card.deleted == true) continue;

      final factInfo = await fs.extractFactContentFromFile(userId, cardId);
      final assetDiagnostics = await collectAssetDiagnosticsForUser(
        userId: userId,
        card: card,
        factContent: factInfo?.content,
      );
      summaries.add(_summarizeCard(
        cardId: cardId,
        card: card,
        factContent: factInfo?.content,
        assetDiagnostics: assetDiagnostics,
      ));
    }

    return {
      'kind': 'recent_timeline_cards',
      'user_id': userId,
      'limit': safeLimit,
      'count': summaries.length,
      'can_verify_current_screen': false,
      'cards': summaries,
    };
  }

  static Future<Map<String, dynamic>> inspectTimelineCardForUser({
    required String userId,
    required String cardId,
  }) async {
    final fs = FileSystemService.instance;
    final card = await _safeReadCard(userId, cardId);
    if (card == null) {
      return _notFound(cardId, 'Card YAML was not found or could not be read.');
    }

    final factInfo = await fs.extractFactContentFromFile(userId, cardId);
    final assetDiagnostics = await collectAssetDiagnosticsForUser(
      userId: userId,
      card: card,
      factContent: factInfo?.content,
    );
    final renderPath = buildRenderPath(card, assetDiagnostics);

    return {
      'kind': 'timeline_card_inspection',
      'card_id': cardId,
      'card_found': true,
      'fact_found': factInfo != null,
      'can_verify_current_screen': false,
      'card': _summarizeCard(
        cardId: cardId,
        card: card,
        factContent: factInfo?.content,
        assetDiagnostics: assetDiagnostics,
      ),
      'ui_configs': card.uiConfigs.map(_summarizeUiConfig).toList(),
      'fact_excerpt': _excerpt(factInfo?.content),
      'asset_diagnostics': assetDiagnostics.map((a) => a.toJson()).toList(),
      'render_path': renderPath,
      'warnings': _buildWarnings(
        card: card,
        factFound: factInfo != null,
        assetDiagnostics: assetDiagnostics,
      ),
    };
  }

  static Future<Map<String, dynamic>> inspectTimelineCardAssetsForUser({
    required String userId,
    required String cardId,
  }) async {
    final fs = FileSystemService.instance;
    final card = await _safeReadCard(userId, cardId);
    if (card == null) {
      return _notFound(cardId, 'Card YAML was not found or could not be read.');
    }

    final factInfo = await fs.extractFactContentFromFile(userId, cardId);
    final assetDiagnostics = await collectAssetDiagnosticsForUser(
      userId: userId,
      card: card,
      factContent: factInfo?.content,
    );

    return {
      'kind': 'timeline_card_asset_inspection',
      'card_id': cardId,
      'card_found': true,
      'fact_found': factInfo != null,
      'asset_count': assetDiagnostics.length,
      'missing_asset_count':
          assetDiagnostics.where((a) => !a.assetExists).length,
      'missing_analysis_count':
          assetDiagnostics.where((a) => !a.analysisExists).length,
      'missing_ocr_count': assetDiagnostics.where((a) => !a.ocrExists).length,
      'assets': assetDiagnostics.map((a) => a.toJson()).toList(),
      'can_verify_current_screen': false,
    };
  }

  static Future<Map<String, dynamic>> describeTimelineRenderPathForUser({
    required String userId,
    required String cardId,
  }) async {
    final fs = FileSystemService.instance;
    final card = await _safeReadCard(userId, cardId);
    if (card == null) {
      return _notFound(cardId, 'Card YAML was not found or could not be read.');
    }

    final factInfo = await fs.extractFactContentFromFile(userId, cardId);
    final assetDiagnostics = await collectAssetDiagnosticsForUser(
      userId: userId,
      card: card,
      factContent: factInfo?.content,
    );

    return {
      'kind': 'timeline_render_path',
      'card_id': cardId,
      'render_path': buildRenderPath(card, assetDiagnostics),
      'important_note':
          'Normal Timeline rendering uses ui_configs. Raw fact assets only become visible if the chosen template references them, or when the user toggles classic mode where available.',
      'can_verify_current_screen': false,
    };
  }

  static Future<List<TimelineAssetDiagnostic>> collectAssetDiagnosticsForUser({
    required String userId,
    CardData? card,
    String? factContent,
  }) async {
    final fs = FileSystemService.instance;
    final refs = <_FsRef>[];
    if (factContent != null) {
      refs.addAll(_extractFsRefs(factContent, source: 'fact_markdown'));
    }
    if (card != null) {
      for (var i = 0; i < card.uiConfigs.length; i++) {
        final config = card.uiConfigs[i];
        refs.addAll(_extractFsRefs(
          jsonEncode(config.toJson()),
          source: 'ui_config[$i]:${config.templateId}',
        ));
      }
    }

    final deduped = <String, _FsRef>{};
    for (final ref in refs) {
      deduped['${ref.source}|${ref.filename}'] = ref;
    }

    final assetsPath = fs.getAssetsPath(userId);
    final diagnostics = <TimelineAssetDiagnostic>[];
    for (final ref in deduped.values) {
      final assetPath = path.join(assetsPath, ref.filename);
      final analysisPath = '$assetPath.analysis.txt';
      final ocrPath = '$assetPath.ocr.txt';
      diagnostics.add(TimelineAssetDiagnostic(
        source: ref.source,
        filename: ref.filename,
        kind: ref.kind,
        assetPath: assetPath,
        assetExists: await File(assetPath).exists(),
        analysisExists: await File(analysisPath).exists(),
        ocrExists: await File(ocrPath).exists(),
      ));
    }
    return diagnostics;
  }

  static List<Map<String, dynamic>> extractFsRefsForTesting(
    String input, {
    String source = 'test',
  }) {
    return _extractFsRefs(input, source: source)
        .map((r) => r.toJson())
        .toList();
  }

  static List<_FsRef> _extractFsRefs(String input, {required String source}) {
    final refs = <_FsRef>[];
    final pattern = RegExp(r'''fs://([^\s\)\]"']+)''');
    for (final match in pattern.allMatches(input)) {
      final filename = match.group(1)?.trim() ?? '';
      if (filename.isEmpty) continue;
      refs.add(_FsRef(
        source: source,
        filename: filename,
        kind: _guessAssetKind(filename),
      ));
    }
    return refs;
  }

  static Map<String, dynamic> buildRenderPath(
    CardData card,
    List<TimelineAssetDiagnostic> assetDiagnostics,
  ) {
    final templates = card.uiConfigs.map((c) => c.templateId).toList();
    final hasLegacyHtml = card.uiConfigs.any(
      (c) =>
          c.templateId == 'legacy_html' && _stringValue(c.data['html']) != '',
    );
    final hasNativeConfigs = card.uiConfigs.any(
      (c) => c.templateId != 'legacy_html',
    );
    final configImageRefs = card.uiConfigs
        .expand((c) => _extractFsRefs(jsonEncode(c.toJson()),
            source: 'ui_config:${c.templateId}'))
        .where((r) => r.kind == 'image')
        .toList();
    final factImageRefs =
        assetDiagnostics.where((a) => a.kind == 'image').toList();

    final steps = <String>[];
    if (card.uiConfigs.isEmpty) {
      steps.add('No ui_configs: normal Timeline has no card body to render.');
    } else {
      for (final config in card.uiConfigs) {
        if (config.templateId == 'legacy_html') {
          final html = _stringValue(config.data['html']);
          steps.add(html.isEmpty
              ? 'legacy_html config is present but html is empty, so Timeline returns an empty widget.'
              : 'legacy_html config renders inside HtmlWebViewCard.');
        } else {
          steps.add(
            '${config.templateId} renders through NativeCardFactory with its data object.',
          );
        }
      }
    }
    steps.add(
      'Long-press classic mode can synthesize a classic_card from raw fact assets when the card has user raw input.',
    );

    return {
      'status': card.status,
      'templates': templates,
      'uses_webview': hasLegacyHtml,
      'uses_native_card_factory': hasNativeConfigs,
      'normal_mode_has_image_refs_in_ui_config': configImageRefs.isNotEmpty,
      'fact_has_image_assets': factImageRefs.isNotEmpty,
      'missing_asset_count':
          assetDiagnostics.where((a) => !a.assetExists).length,
      'steps': steps,
    };
  }

  static Map<String, dynamic> _summarizeCard({
    required String cardId,
    required CardData card,
    required String? factContent,
    required List<TimelineAssetDiagnostic> assetDiagnostics,
  }) {
    return {
      'id': cardId,
      'title': card.title,
      'status': card.status,
      'timestamp': card.timestamp,
      'tags': card.tags,
      'ui_templates': card.uiConfigs.map((c) => c.templateId).toList(),
      'fact_found': factContent != null,
      'fact_excerpt': _excerpt(factContent, maxChars: 160),
      'asset_ref_count': assetDiagnostics.length,
      'image_ref_count':
          assetDiagnostics.where((a) => a.kind == 'image').length,
      'missing_asset_count':
          assetDiagnostics.where((a) => !a.assetExists).length,
      'failure_reason': card.failureReason,
      'render_summary': buildRenderPath(card, assetDiagnostics),
    };
  }

  static Map<String, dynamic> _summarizeUiConfig(UiConfig config) {
    final encoded = jsonEncode(config.toJson());
    final refs =
        _extractFsRefs(encoded, source: 'ui_config:${config.templateId}');
    final html = _stringValue(config.data['html']);
    return {
      'template_id': config.templateId,
      'data_keys': config.data.keys.toList(),
      'fs_refs': refs.map((r) => r.toJson()).toList(),
      'html_length': html.length,
      'has_html': html.isNotEmpty,
      'has_images_field': config.data['images'] is List,
      'images_field_count': config.data['images'] is List
          ? (config.data['images'] as List).length
          : 0,
    };
  }

  static List<String> _buildWarnings({
    required CardData card,
    required bool factFound,
    required List<TimelineAssetDiagnostic> assetDiagnostics,
  }) {
    final warnings = <String>[];
    if (!factFound) {
      warnings
          .add('Fact entry is missing, so raw text/assets cannot be hydrated.');
    }
    if (card.status == 'failed') {
      warnings.add(
        'Card status is failed. retry_failed_timeline_card may requeue it.',
      );
    }
    if (card.uiConfigs.isEmpty) {
      warnings.add(
          'Card has no ui_configs, so normal Timeline may render no body.');
    }
    final missingAssets =
        assetDiagnostics.where((a) => !a.assetExists).toList();
    if (missingAssets.isNotEmpty) {
      warnings.add(
        'Some fs:// assets are missing from Facts/assets: ${missingAssets.map((a) => a.filename).join(', ')}.',
      );
    }
    final factImages = assetDiagnostics
        .where((a) => a.kind == 'image' && a.source == 'fact_markdown')
        .toList();
    final uiImageRefs = card.uiConfigs
        .expand((c) {
          return _extractFsRefs(jsonEncode(c.toJson()),
              source: 'ui_config:${c.templateId}');
        })
        .where((r) => r.kind == 'image')
        .toList();
    if (factImages.isNotEmpty && uiImageRefs.isEmpty) {
      warnings.add(
        'Fact has image assets, but normal ui_configs do not reference those images. The Timeline may not show images unless classic mode or another template uses them.',
      );
    }
    return warnings;
  }

  static Future<CardData?> _safeReadCard(String userId, String cardId) async {
    try {
      return await FileSystemService.instance.readCardFile(userId, cardId);
    } catch (e, stackTrace) {
      _logger.warning('Failed to read card $cardId', e, stackTrace);
      return null;
    }
  }

  static Map<String, dynamic> _notFound(String cardId, String message) {
    return {
      'kind': 'timeline_card_not_found',
      'card_id': cardId,
      'card_found': false,
      'message': message,
      'can_verify_current_screen': false,
    };
  }

  static Future<String> _resolveUserId() async {
    final contextUserId =
        AgentCallToolContext.current?.state.metadata['userId']?.toString();
    if (contextUserId != null && contextUserId.trim().isNotEmpty) {
      return contextUserId.trim();
    }
    final userId = await UserStorage.getUserId();
    if (userId == null || userId.trim().isEmpty) {
      throw StateError('User not logged in, cannot inspect Timeline data.');
    }
    return userId.trim();
  }

  static String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value;
  }

  static int _intArg(
    dynamic value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return (parsed ?? fallback).clamp(min, max).toInt();
  }

  static String _json(Map<String, dynamic> value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static String _excerpt(String? text, {int maxChars = 240}) {
    final cleaned = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= maxChars) return cleaned;
    return '${cleaned.substring(0, maxChars)}...';
  }

  static String _stringValue(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static String _guessAssetKind(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.heic')) {
      return 'image';
    }
    if (lower.endsWith('.m4a') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.caf')) {
      return 'audio';
    }
    return 'unknown';
  }
}

class TimelineAssetDiagnostic {
  final String source;
  final String filename;
  final String kind;
  final String assetPath;
  final bool assetExists;
  final bool analysisExists;
  final bool ocrExists;

  const TimelineAssetDiagnostic({
    required this.source,
    required this.filename,
    required this.kind,
    required this.assetPath,
    required this.assetExists,
    required this.analysisExists,
    required this.ocrExists,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'filename': filename,
      'kind': kind,
      'asset_exists': assetExists,
      'analysis_exists': analysisExists,
      'ocr_exists': ocrExists,
      'asset_path': assetPath,
    };
  }
}

class _FsRef {
  final String source;
  final String filename;
  final String kind;

  const _FsRef({
    required this.source,
    required this.filename,
    required this.kind,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'filename': filename,
      'kind': kind,
    };
  }
}
