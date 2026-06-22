import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/utils/logger.dart';

final _logger = getLogger('MigrateCardsFactAssets');

/// Migration key in `_System/migration_state.json`.
const _migrationKey = 'cards_fact_assets_created_at_v2';

/// Per-user lock so a migration can't run twice concurrently.
final Map<String, Lock> _locks = {};
Lock _lockFor(String userId) => _locks.putIfAbsent(userId, () => Lock());

/// One-time migration of legacy cards to the self-contained card structure.
///
/// Historically a card's original user input and its media references
/// (`![image](fs://...)` / `[audio](fs://...)`) lived in the
/// `Facts/YYYY/MM/DD.md` files, and card display read them back from there.
/// Cards now carry that data themselves via `fact`, `assets`, and `created_at`.
///
/// This walks every existing card that is missing any of those fields, pulls
/// the legacy entry out of the Facts file, splits media markers into `assets`,
/// stores the remaining text in `fact`, and writes the legacy entry timestamp
/// into `created_at`. It is idempotent: once completed it records a flag in
/// `_System/migration_state.json` and returns immediately on later launches.
///
/// Image-analysis / OCR sidecar text is intentionally not migrated onto the
/// card; `fact` holds the user's original record only.
Future<void> migrateCardsToFactAssets(String userId) async {
  await _lockFor(userId).synchronized(() async {
    final fs = FileSystemService.instance;

    final state = await _readMigrationState(userId);
    if (state[_migrationKey] == true) {
      return;
    }

    _logger.info('Migrating cards to fact/assets structure for user $userId');

    var migrated = 0;
    var scanned = 0;
    try {
      final cardFiles = await fs.listAllCardFiles(userId);
      for (final cardFile in cardFiles) {
        final factId = fs.factIdFromCardPath(cardFile);
        if (factId == null) continue;
        scanned++;

        try {
          final card = await fs.readCardFile(userId, factId);
          if (card == null || card.deleted == true) continue;

          final needsFactAssets =
              (card.fact ?? '').trim().isEmpty && card.assets.isEmpty;
          final needsCreatedAt = card.createdAt == null;
          if (!needsFactAssets && !needsCreatedAt) {
            continue;
          }

          final factInfo =
              await _extractLegacyFactContentFromFile(fs, userId, factId);
          if (factInfo == null) continue;

          String? fact;
          List<String>? assets;
          if (needsFactAssets) {
            final split = _splitFactAndAssets(factInfo.content);
            if (split.$1.isNotEmpty || split.$2.isNotEmpty) {
              fact = split.$1;
              assets = split.$2;
            }
          }

          if (fact == null && assets == null && !needsCreatedAt) continue;

          await fs.updateCardFile(
            userId,
            factId,
            (c) => c.copyWith(
              fact: fact,
              assets: assets,
              createdAt: needsCreatedAt ? factInfo.timestamp : null,
            ),
          );
          migrated++;
        } catch (e, st) {
          _logger.warning('Failed to migrate card $factId', e, st);
        }
      }
    } catch (e, st) {
      // A scan failure should not permanently block the app; leave the flag
      // unset so the migration retries on the next launch.
      _logger.severe('Card fact/assets migration failed mid-scan', e, st);
      return;
    }

    state[_migrationKey] = true;
    await _writeMigrationState(userId, state);
    _logger.info(
      'Card fact/assets migration complete: migrated $migrated of $scanned cards',
    );
  });
}

/// Split legacy fact-file content into (fact text, asset references).
///
/// Asset references are kept verbatim in the same markdown form they were
/// written (`![image](fs://...)` / `[audio](fs://...)`), which is exactly what
/// card `assets` stores. The fact text is the remaining content with those
/// markers removed and surrounding whitespace collapsed.
(String, List<String>) _splitFactAndAssets(String content) {
  final markerPattern = RegExp(r'!?\[[^\]]*\]\(fs://[^)]+\)');

  final assets = <String>[];
  for (final match in markerPattern.allMatches(content)) {
    final marker = match.group(0)!.trim();
    if (marker.isNotEmpty) assets.add(marker);
  }

  final fact = content
      .replaceAll(markerPattern, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  return (fact, assets);
}

class _LegacyFactContent {
  final int timestamp;
  final String content;

  const _LegacyFactContent({
    required this.timestamp,
    required this.content,
  });
}

Future<_LegacyFactContent?> _extractLegacyFactContentFromFile(
  FileSystemService fs,
  String userId,
  String factId,
) async {
  final factDate = fs.parseFactIdDate(factId);
  final bodyContent = await _readLegacyDailyFactBody(fs, userId, factDate);
  if (bodyContent.trim().isEmpty) return null;

  final simpleFactId = _extractSimpleFactId(factId);
  final idPattern =
      '(?:${RegExp.escape(simpleFactId)}|${RegExp.escape(factId)})';
  final headingPattern = RegExp(
    '##\\s*<id:$idPattern>\\s*(\\d{2}:\\d{2}:\\d{2})',
  );
  final headingMatch = headingPattern.firstMatch(bodyContent);
  if (headingMatch == null) return null;

  final titleEndPos = bodyContent.indexOf('\n', headingMatch.start);
  if (titleEndPos == -1) return null;

  var contentStartPos = titleEndPos + 1;
  if (contentStartPos < bodyContent.length &&
      bodyContent[contentStartPos] == '\n') {
    contentStartPos += 1;
  }

  final remainingContent = bodyContent.substring(contentStartPos);
  final nextEntryMatch =
      RegExp(r'##\s*<id:(?:ts_\d+|\d{4}/\d{2}/\d{2}\.md#ts_\d+)>')
          .firstMatch(remainingContent);
  final entryContent = nextEntryMatch != null
      ? remainingContent.substring(0, nextEntryMatch.start).trim()
      : remainingContent.trim();

  final timeParts = headingMatch.group(1)!.split(':').map(int.parse).toList();
  final timestamp = DateTime(
        factDate.year,
        factDate.month,
        factDate.day,
        timeParts[0],
        timeParts[1],
        timeParts[2],
      ).millisecondsSinceEpoch ~/
      1000;

  return _LegacyFactContent(timestamp: timestamp, content: entryContent);
}

Future<String> _readLegacyDailyFactBody(
  FileSystemService fs,
  String userId,
  DateTime date,
) async {
  final file = File(_legacyDailyFactPath(fs, userId, date));
  if (!await file.exists()) return '';

  final content = await file.readAsString();
  return content.replaceFirst(RegExp(r'^---\r?\n[\s\S]*?\r?\n---\r?\n?'), '');
}

String _legacyDailyFactPath(
  FileSystemService fs,
  String userId,
  DateTime date,
) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return p.join(fs.getFactsPath(userId), year, month, '$day.md');
}

String _extractSimpleFactId(String factId) {
  final index = factId.indexOf('#');
  return index == -1 ? factId : factId.substring(index + 1);
}

String _migrationStatePath(String userId) => p.join(
      FileSystemService.instance.getSystemPath(userId),
      'migration_state.json',
    );

Future<Map<String, dynamic>> _readMigrationState(String userId) async {
  final file = File(_migrationStatePath(userId));
  if (!await file.exists()) return <String, dynamic>{};
  try {
    final data = jsonDecode(await file.readAsString());
    if (data is Map) return Map<String, dynamic>.from(data);
  } catch (e) {
    _logger.warning('Failed to parse migration_state.json: $e');
  }
  return <String, dynamic>{};
}

Future<void> _writeMigrationState(
  String userId,
  Map<String, dynamic> state,
) async {
  final path = _migrationStatePath(userId);
  final dir = Directory(p.dirname(path));
  if (!await dir.exists()) await dir.create(recursive: true);

  state['updated_at'] = DateTime.now().toIso8601String();
  const encoder = JsonEncoder.withIndent('  ');
  final tmpFile = File('$path.tmp');
  await tmpFile.writeAsString(encoder.convert(state));
  await tmpFile.rename(path);
}
