import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:memex/utils/logger.dart';
import 'file_system_service.dart';
import 'package:memex/domain/models/card_detail_model.dart';
import 'package:memex/domain/models/card_model.dart';
import 'html_templates.dart';

final _logger = getLogger('CardRenderer');

/// Native card template IDs
const Set<String> _nativeCardTemplates = {
  // Old templates
  'classic_card',
  'hero_card',
  'data_card',
  'list_card',
  'quote_card',
  'timeline_card',
  'map_focus_card',
  'ticket_card',
  'compact_card',
  // Entities
  'link',
  'person',
  'place',
  'spec_sheet',
  'transaction',
  // Quantifiable
  'metric',
  'rating',
  'mood',
  'progress',
  // Temporal
  'event',
  'duration',
  'task',
  'routine',
  'procedure',
  // Textual
  'snippet',
  'article',
  'conversation',
  'quote',
  // Visual
  'snapshot',
  'gallery',
  'video',
  'canvas',
  // V1 Native Widgets
  'map_card_v1',
  'route_map_card_v1',
  'highlight_card_v1',
  'composition_card_v1',
  'contrast_card_v1',
  'gallery_card_v1',
  'bubble_chart_card_v1',
  'progress_chart_card_v1',
  'radar_chart_card_v1',
  'trend_chart_card_v1',
  'bar_chart_card_v1',
  'timeline_card_v1',
  'system_task',
  'schedule_briefing',
};

/// Result of card rendering
class CardRenderResult {
  final String? html;
  final List<UiConfig> uiConfigs;
  final String status;

  CardRenderResult({
    this.html,
    required this.uiConfigs,
    required this.status,
  });
}

/// Check if a template ID is a native card
bool isNativeCard(String? templateId) {
  if (templateId == null || templateId.isEmpty) {
    return false;
  }
  return _nativeCardTemplates.contains(templateId);
}

/// Replace fs:// URLs in data recursively
Future<Map<String, dynamic>> replaceFsInData(
    Map<String, dynamic> data, String userId) async {
  final result = <String, dynamic>{};
  for (final entry in data.entries) {
    final key = entry.key;
    final value = entry.value;

    if (value is String && value.startsWith('fs://')) {
      // Replace fs:// URL with HTTP URL
      result[key] = await FileSystemService.convertFsToLocalHttp(value, userId);
    } else if (value is List) {
      // Process list items
      final processedList = <dynamic>[];
      for (final item in value) {
        if (item is String && item.startsWith('fs://')) {
          processedList
              .add(await FileSystemService.convertFsToLocalHttp(item, userId));
        } else if (item is Map) {
          processedList.add(
              await replaceFsInData(Map<String, dynamic>.from(item), userId));
        } else {
          processedList.add(item);
        }
      }
      result[key] = processedList;
    } else if (value is Map) {
      // Recursively process nested maps
      result[key] =
          await replaceFsInData(Map<String, dynamic>.from(value), userId);
    } else {
      result[key] = value;
    }
  }
  return result;
}

/// Render a card (HTML or Native)
/// Returns CardRenderResult with html (for HTML cards) or data (for Native cards)
Future<CardRenderResult> renderCard({
  required String userId,
  required CardData cardData,
  String? factContent,
}) async {
  final fileSystemService = FileSystemService.instance;
  final cardStatus = cardData.status;

  final List<UiConfig> uiConfigs = cardData.uiConfigs;

  // Handle processing or failed status
  if (cardStatus == 'processing' || cardStatus == 'failed') {
    // For native cards, return data with status
    if (uiConfigs.isNotEmpty &&
        uiConfigs.every((c) => isNativeCard(c.templateId))) {
      // Replace fs:// in all templates
      final processedConfigs = <UiConfig>[];
      for (var config in uiConfigs) {
        final processedData = await replaceFsInData(config.data, userId);
        processedConfigs
            .add(UiConfig(templateId: config.templateId, data: processedData));
      }

      return CardRenderResult(
        uiConfigs: processedConfigs,
        status: cardStatus,
      );
    }

    // For HTML cards, return HTML
    String contentToDisplay = "";
    contentToDisplay = cardStatus == 'processing'
        ? "Parsing your record..."
        : "Processing failed";
    if (factContent != null && factContent.isNotEmpty) {
      contentToDisplay = factContent;
    }

    final htmlContent = cardStatus == 'processing'
        ? getProcessingCardHtml(contentToDisplay)
        : getFallbackCardHtml(contentToDisplay);
    final finalHtml =
        await fileSystemService.replaceFsInHtml(htmlContent, userId);
    return CardRenderResult(
      html: finalHtml,
      status: cardStatus,
      uiConfigs: [], // fallback html
    );
  }

  // Handle completed status
  if (uiConfigs.isEmpty) {
    // No template, use fallback
    String contentToDisplay = "Unable to parse your record.";
    if (factContent != null && factContent.isNotEmpty) {
      contentToDisplay = factContent;
    }
    final htmlContent = getFallbackCardHtml(contentToDisplay);
    final finalHtml =
        await fileSystemService.replaceFsInHtml(htmlContent, userId);
    return CardRenderResult(
      html: finalHtml,
      status: 'completed',
      uiConfigs: [],
    );
  }

  // Process UI configs - support mixing native and HTML templates
  // If a template ID is not native, we attempt to render it as an HTML template.
  final processedConfigs = <UiConfig>[];

  for (var config in uiConfigs) {
    final htmlTemplate =
        await fileSystemService.readTemplateHtml(userId, config.templateId);
    if (htmlTemplate != null) {
      try {
        var htmlContent =
            fileSystemService.renderHtmlTemplate(htmlTemplate, config.data);
        htmlContent =
            await fileSystemService.replaceFsInHtml(htmlContent, userId);

        // Convert to legacy_html config so UI knows to render as WebView.
        processedConfigs.add(
            UiConfig(templateId: 'legacy_html', data: {'html': htmlContent}));
      } catch (e) {
        _logger
            .warning('Failed to render HTML template ${config.templateId}: $e');
        final processedData = await replaceFsInData(config.data, userId);
        processedConfigs
            .add(UiConfig(templateId: config.templateId, data: processedData));
      }
    } else if (isNativeCard(config.templateId)) {
      // Native or already processed HTML (though usually not expected in input)
      final processedData = await replaceFsInData(config.data, userId);
      processedConfigs
          .add(UiConfig(templateId: config.templateId, data: processedData));
    } else {
      final validTemplateId = config.templateId;

      // Unknown template and no HTML file found.
      // For legacy_html we need to normalize embedded fs:// references in
      // the html payload in addition to normal data field replacement.
      final processedData = await replaceFsInData(config.data, userId);

      Map<String, dynamic> updatedData = processedData;
      if (validTemplateId == 'legacy_html') {
        final htmlContent = processedData['html'];
        if (htmlContent is String) {
          final replacedHtml =
              await fileSystemService.replaceFsInHtml(htmlContent, userId);
          updatedData = {
            ...processedData,
            'html': replacedHtml,
          };
        }
      }

      processedConfigs
          .add(UiConfig(templateId: validTemplateId, data: updatedData));
    }
  }

  return CardRenderResult(
    uiConfigs: processedConfigs,
    status: 'completed',
  );
}

/// Extract display assets and raw text from a card's own fields.
///
/// Assets come from [CardData.assets] (a list of markdown-style references
/// `![image](fs://…)` / `[audio](fs://…)`); raw text comes from
/// [CardData.fact]. Returns a map with 'assets' (List<AssetData>) and
/// 'rawText' (String?).
Future<Map<String, dynamic>> extractAssetsAndRawText(
    String userId, CardData card) async {
  final assets = <AssetData>[];
  final fileSystemService = FileSystemService.instance;
  final assetsPath = fileSystemService.getAssetsPath(userId);

  // Each entry is a full markdown reference. Images use the `![...](fs://…)`
  // form (leading `!`); audio uses `[...](fs://…)`.
  final fsPattern = RegExp(r'\(fs://([^\)]+)\)');
  for (final ref in card.assets) {
    final match = fsPattern.firstMatch(ref);
    if (match == null) continue;
    final fileName = match.group(1)!;
    final isImage = ref.trimLeft().startsWith('!');

    final filePath = path.join(assetsPath, fileName);
    if (!await File(filePath).exists()) continue;

    final url =
        await FileSystemService.convertFsToLocalHttp('fs://$fileName', userId);
    assets.add(AssetData(type: isImage ? 'image' : 'audio', url: url));
  }

  final rawText = card.fact?.trim();

  return {
    'assets': assets,
    'rawText': (rawText != null && rawText.isNotEmpty) ? rawText : null,
  };
}
