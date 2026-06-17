import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:memex/agent/prompts.dart';
import 'package:memex/utils/date_util.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/file_operation_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/time_context.dart';
import 'dart:io';

final getCurrentTimeTool = Tool(
  name: 'getCurrentTime',
  description: 'Get current time and week id',
  parameters: {
    'type': 'object',
    'properties': {},
  },
  executable: () {
    final now = DateTime.now();

    // ISO week year can be different from calendar year (e.g. early Jan)
    // Adjust year if needed.
    // For simplicity, let's trust the Monday-based calc.
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final thursday = monday.add(const Duration(days: 3));
    final year = thursday.year;

    final weekId = '${year}_W${isoWeekNumber(now)}';
    return "Current Local Time: ${formatLocalDateTimeWithZone(now)}, Current WeekId: $weekId";
  },
);

/// Mint a fresh `fact_id` for a brand-new record, reserving the id by writing a
/// `processing` placeholder card. This is a SuperAgent base tool (not buried in
/// a skill) so the agent can mint without first activating
/// `manage_timeline_card` — capture then becomes a clean "mint, then delegate"
/// flow. It writes data, so it is intentionally excluded from Quick Query
/// (read-only) mode.
final mintRecordFactIdTool = Tool(
  name: 'mint_record_fact_id',
  description:
      "Mint a fresh fact_id for a brand-new record BEFORE creating its card. "
      "The system reserves the id (it never collides and is never guessed by "
      "you). Pass the returned fact_id into the task_brief of every worker for "
      "this record (card / PKM / schedule) so they all link to one identity. "
      "Use this only for a NEW record — to edit an existing card, reuse that "
      "card's id instead.",
  parameters: {
    'type': 'object',
    'properties': {
      'content_creation_date': {
        'type': 'string',
        'description':
            'Optional creation date of the record (e.g. an image capture time), in format "YYYY-MM-DD HH:MM:SS". Determines which day the id is filed under. If omitted, the current time is used.'
      },
    },
  },
  executable: (String? content_creation_date) async {
    final context = AgentCallToolContext.current;
    if (context == null) {
      throw StateError(
          "mint_record_fact_id must be called within an agent execution context.");
    }
    final userId = context.state.metadata['userId'] as String;
    DateTime? date;
    if (content_creation_date != null &&
        content_creation_date.trim().isNotEmpty) {
      date = DateTime.tryParse(content_creation_date.trim());
    }
    final factId =
        await FileSystemService.instance.allocateCardFactId(userId, date: date);
    getLogger('CommonTools').info('Minted fact_id: $factId');
    return AgentToolResult(
      content: TextPart(
          "Minted fact_id: $factId. Use this exact id when saving the card "
          "(save_timeline_card), organizing it into PKM "
          "(`<!-- fact_id: $factId -->`), and updating the schedule, so every "
          "part of this record shares one identity."),
      metadata: {
        'artifact': {
          'type': 'fact_id',
          'id': factId,
        },
      },
    );
  },
);

final getPkmOverviewTool = Tool(
  name: 'get_pkm_overview',
  description:
      'Retrieve the current PKM knowledge base directory structure and file '
      'information on demand. The PKM tree is NOT pre-loaded into your '
      'context — call this whenever you need to see the current structure '
      'before reading or organizing knowledge.',
  parameters: {
    'type': 'object',
    'properties': {},
  },
  executable: () async {
    final context = AgentCallToolContext.current;
    if (context == null) {
      throw StateError(
          "get_pkm_overview must be called within an agent execution context.");
    }
    final userId = context.state.metadata['userId'] as String;
    final fileService = FileSystemService.instance;
    final fileOpService = FileOperationService.instance;

    final workingDirectory = fileService.getWorkspacePath(userId);
    final pkmPath = fileService.getPkmPath(userId);
    final pkmDir = Directory(pkmPath);

    String pkmStructure = '';
    try {
      if (pkmDir.existsSync()) {
        pkmStructure = await fileOpService.listDirectory(
          dirPath: pkmPath,
          workingDirectory: workingDirectory,
        );
      } else {
        pkmStructure = Prompts.pkmAgentDirectoryNotCreated;
      }
    } catch (e) {
      getLogger('PkmAgent').warning('Failed to get PKM structure: $e');
      pkmStructure = Prompts.pkmAgentDirectoryStructureError(e.toString());
    }
    final header = pkmStructure.contains('passing a specific path') ? Prompts.pkmAgentTruncatedOverviewHeader : Prompts.pkmAgentFullOverviewHeader;
    return '''<system-reminder>
$header
$pkmStructure
</system-reminder>''';
  },
);
