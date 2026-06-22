import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/agent/run_mode/agent_action_approval_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

// Tool executable parameter names mirror JSON schema keys.
// ignore_for_file: non_constant_identifier_names

/// Skill for PKM Agent - organizes user input into P.A.R.A knowledge base structure
class PkmSkill extends Skill {
  /// When provided, [stopAfterUpdateCardInsightRef] must be a single-element
  /// list; read tool sets ref[0] = false when it returns system-reminder so
  /// update_card_insight won't stop the agent (model can fix structure).
  PkmSkill({
    super.forceActivate,
    List<bool>? stopAfterUpdateCardInsightRef,
    String? workingDirectory,
  }) : super(
          name: "manage_pkm", // Renamed to capability-focused name
          description:
              "Organizes user input into P.A.R.A (Projects, Areas, Resources, Archive) knowledge base structure. "
              "Extracts information from diverse inputs and organizes them systematically. "
              "Also updates card insights.",
          systemPrompt: Prompts.pkmSkillSystemPrompt(
            workingDirectory ?? '/',
            UserStorage.l10n.pkmPARAStructureExample,
            UserStorage.l10n.pkmFileLanguageInstruction,
            UserStorage.l10n.pkmInsightLanguageInstruction,
          ),
          tools: _buildTools(stopAfterUpdateCardInsightRef),
        );

  static List<Tool> _buildTools(List<bool>? stopAfterUpdateCardInsightRef) {
    final logger = getLogger('PkmSkill');

    return [
      Tool(
        name: 'update_timeline_card_insight',
        description: Prompts.pkmSkillUpdateCardInsightToolDescription,
        parameters: Prompts.pkmSkillUpdateCardInsightToolParameters,
        executable: (
          String fact_id,
          String insight_text,
          List? related_fact_ids,
        ) async {
          final context = AgentCallToolContext.current;
          if (context == null) {
            throw StateError(
                "update_timeline_card_insight must be called within an agent execution context.");
          }
          final userId = context.state.metadata['userId'] as String;
          final fileService = FileSystemService.instance;

          final denied = await gateMutatingToolCall(
            toolName: 'update_timeline_card_insight',
            summary: fact_id,
            details: {
              'insight': insight_text.length > 120
                  ? '${insight_text.substring(0, 120)}…'
                  : insight_text,
            },
          );
          if (denied != null) return denied;

          // Validate the target card exists. fact_id identity now lives on the
          // card itself (Cards/*.yaml), not in a Facts file — so check the card,
          // and never create a phantom card from a wrong/hallucinated id.
          CardData? existingCard;
          try {
            existingCard = await fileService.readCardFile(userId, fact_id);
          } catch (e) {
            throw ArgumentError(
                "Invalid fact_id '$fact_id'. Expected format 2026/01/20.md#ts_5, referencing an existing card.");
          }
          if (existingCard == null) {
            throw ArgumentError(
                "Card $fact_id does not exist. update_timeline_card_insight only updates an existing card's insight; create the card with save_timeline_card first.");
          }

          // Validate related_fact_ids: drop self-references and any id that does
          // not resolve to a real card (the model must not guess fact_ids).
          final droppedRelated = <String>[];
          final validRelated = <String>[];
          for (final rid in (related_fact_ids ?? const [])) {
            final id = rid?.toString().trim() ?? '';
            if (id.isEmpty || id == fact_id) continue;
            CardData? relatedCard;
            try {
              relatedCard = await fileService.readCardFile(userId, id);
            } catch (_) {
              relatedCard = null;
            }
            if (relatedCard != null) {
              validRelated.add(id);
            } else {
              droppedRelated.add(id);
            }
          }
          if (droppedRelated.isNotEmpty) {
            logger.warning(
                'update_timeline_card_insight dropped non-existent related_fact_ids: ${droppedRelated.join(', ')}');
          }

          final relatedCount = validRelated.length;
          final cardPath = fileService.getCardPath(userId, fact_id);

          final relatedFacts =
              validRelated.map((id) => RelatedFact(id: id)).toList();
          final insightData = CardInsight(
            characterId: '0',
            text: insight_text,
            relatedFacts: relatedFacts,
          );

          final updatedCardData = await fileService.updateCardFile(
            userId,
            fact_id,
            (card) => card.copyWith(insight: insightData),
          );

          final stopFlag = stopAfterUpdateCardInsightRef != null
              ? stopAfterUpdateCardInsightRef[0]
              : false;

          if (updatedCardData == null) {
            logger.warning(
                "Card file not found for fact_id: $fact_id, maybe it has been deleted");
            throw StateError(
                Prompts.pkmSkillUpdateCardInsightErrorCardNotFound(fact_id));
          }

          // Notify detail page to refresh after insight update
          EventBusService.instance.emitEvent(CardDetailUpdatedMessage(
            cardId: fact_id,
          ));

          return AgentToolResult(
            content: TextPart(Prompts.pkmSkillUpdateCardInsightSuccess(
                cardPath, fact_id, relatedCount)),
            stopFlag: stopFlag,
          );
        },
      ),
      Tool(
        name: 'skip_pkm_organization',
        description: Prompts.pkmSkillSkipOrganizationToolDescription,
        parameters: Prompts.pkmSkillSkipOrganizationToolParameters,
        executable: (String evidence) async {
          final context = AgentCallToolContext.current;
          final factId = context?.state.metadata['factId'];
          if (context != null) {
            context.state.metadata['skippedPkm'] = true;
            context.state.metadata['pkmSkipEvidence'] = evidence;
          }
          logger.info(
            'Skipping PKM organization for fact_id=$factId, evidence=$evidence',
          );

          return AgentToolResult(
            content: TextPart(
              'PKM organization skipped. evidence=$evidence',
            ),
            stopFlag: true,
          );
        },
      ),
    ];
  }
}
