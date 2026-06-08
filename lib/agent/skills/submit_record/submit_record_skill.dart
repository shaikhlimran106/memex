import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';
import 'package:memex/data/repositories/submit_input.dart'
    as submit_input_endpoint;
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/publish_timestamp_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/user_storage.dart';

final _logger = Logger('SubmitRecordSkill');

/// Lets SuperAgent submit text records through the same local-first pipeline as
/// the legacy input sheet.
class SubmitRecordSkill extends Skill {
  SubmitRecordSkill({super.forceActivate})
      : super(
          name: 'submit_record',
          description:
              'Submits a user-facing lifelog or knowledge record into Memex. '
              'Use when the user shares something that should become part of '
              'their timeline, cards, PKM, and follow-up agent workflow.',
          systemPrompt: _buildSystemPrompt(),
          tools: _buildTools(),
        );

  static String _buildSystemPrompt() {
    return '''## Skill Name
`submit_record`

## Purpose
Use this skill to turn the user's current message into a Memex record. This is the controlled path for creating Facts, timeline placeholder cards, and downstream async work such as card generation, PKM organization, comments, indexing, and follow-up routing.

## When to Use
- The user clearly asks to record, publish, remember, log, save, or add something to Memex.
- The user shares a life event, work update, thought, observation, plan, note, receipt-like detail, or knowledge snippet that is likely intended as a timeline/knowledge record.
- The user speaks in a capture-first way, for example "记一下...", "今天...", "刚刚...", "帮我记录...".

## When Not to Use
- The user is only asking a question, chatting casually, or requesting a search/summarization over existing records.
- The user asks to edit an existing card/PKM/setting; use the relevant editing skill instead.
- The user's intent is ambiguous and recording it would be risky. Ask a short clarification first.

## Rules
1. Submit only the actual record content. Do not include your own explanation, tool plan, or hidden reasoning in the record body.
2. Preserve the user's language and tone. Do not translate or rewrite unless the user asks you to polish.
3. After submitting, briefly tell the user that the record was added and that card/PKM processing is continuing asynchronously.
4. If the current chat turn includes attached images and the user wants to save them, pass the provided `image_paths` exactly. Do not invent image paths.
5. If the user only attached images and did not clearly ask to save them, inspect the images and ask whether they should be recorded before calling this tool.
''';
  }

  static List<Tool> _buildTools() {
    return [
      Tool(
        name: 'submit_record',
        description:
            'Submit a text record into Memex using the normal Facts/Card/PKM pipeline.',
        parameters: {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description':
                  'The exact user-facing record content to save. Keep the user language and do not include agent commentary.',
            },
            'image_paths': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Optional image paths supplied by the current chat attachment context. Use exactly the provided paths.',
            },
            'reason': {
              'type': 'string',
              'description':
                  'Optional short internal reason for why this should be recorded.',
            },
          },
          'required': [],
        },
        executable:
            // ignore: non_constant_identifier_names
            (String? content, List<dynamic>? image_paths,
                String? reason) async {
          final trimmed = content?.trim() ?? '';
          final imagePaths = (image_paths ?? const [])
              .map((path) => path.toString().trim())
              .where((path) => path.isNotEmpty)
              .toList();
          if (trimmed.isEmpty && imagePaths.isEmpty) {
            throw ArgumentError(
              'content or image_paths must contain something to record.',
            );
          }

          final userId = await UserStorage.getUserId();
          if (userId == null) {
            throw StateError('User not logged in, cannot submit record.');
          }

          _logger.info(
            'Submitting SuperAgent record for user=$userId, images=${imagePaths.length}, reason=${reason ?? '-'}',
          );

          final payload = <Map<String, dynamic>>[
            if (trimmed.isNotEmpty) {'type': 'text', 'text': trimmed},
            for (final imagePath in imagePaths)
              {
                'type': 'image_url',
                'image_url': {
                  'filePath':
                      FileSystemService.instance.toAbsolutePath(imagePath),
                },
              },
          ];

          final response =
              await submit_input_endpoint.submitInput(userId, payload);

          await PublishTimestampService.saveLastPublishTimestamp(
            DateTime.now().millisecondsSinceEpoch,
          );

          _emitCardAddedIfPossible(response, rawText: trimmed);

          final factId = response['fact_id']?.toString() ?? '';
          return AgentToolResult(
            content: TextPart(
              'Record submitted successfully. fact_id=$factId. '
              'Saved ${imagePaths.length} image attachment(s). '
              'The timeline card, PKM organization, and follow-up agents will continue asynchronously.',
            ),
          );
        },
      ),
    ];
  }

  static void _emitCardAddedIfPossible(
    Map<String, dynamic> response, {
    required String rawText,
  }) {
    final rawCard = response['card'];
    if (rawCard is! Map) return;

    try {
      final card = Map<String, dynamic>.from(rawCard);
      final uiConfigsRaw = card['ui_configs'];
      final uiConfigs = <UiConfig>[];
      if (uiConfigsRaw is List) {
        for (final item in uiConfigsRaw) {
          if (item is Map) {
            uiConfigs.add(UiConfig.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      EventBusService.instance.emitEvent(
        CardAddedMessage(
          id: card['id']?.toString() ?? response['fact_id']?.toString() ?? '',
          html: card['html']?.toString() ?? '',
          timestamp: (card['timestamp'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch ~/ 1000,
          tags: (card['tags'] as List<dynamic>?)
                  ?.map((tag) => tag.toString())
                  .toList() ??
              const [],
          status: card['status']?.toString() ?? 'processing',
          title: card['title']?.toString(),
          uiConfigs: uiConfigs,
          rawText: rawText,
          address: card['address']?.toString(),
        ),
      );
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to emit CardAddedMessage for submitted record',
        e,
        stackTrace,
      );
    }
  }
}
