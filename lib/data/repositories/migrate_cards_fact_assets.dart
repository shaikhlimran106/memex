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
/// Historically a card's original user input (raw text) and its media
/// references (`![image](fs://…)` / `[audio](fs://…)`) lived in the
/// `Facts/年/月/日.md` files, and card display read them back from there. Cards
/// now carry that data themselves via [CardData.fact] (raw text),
/// [CardData.assets] (media references), and [CardData.createdAt] (the legacy
/// fact entry time).
///
/// This walks every existing card that is missing any of those fields, pulls
/// the legacy entry out of the Facts file, splits the media markers into
/// `assets` and the remaining text into `fact`, and writes the legacy entry
/// timestamp into `created_at`. It is idempotent: once completed it records a
/// flag in
/// `_System/migration_state.json` and returns immediately on subsequent runs.
///
/// Image-analysis / OCR sidecar text is intentionally NOT migrated onto the
/// card — `fact` holds the user's original information only.
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

          final factInfo = await fs.extractFactContentFromFile(userId, factId);
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
        'Card fact/assets migration complete: migrated $migrated of $scanned cards');
  });
}

/// Split legacy fact-file content into (fact text, asset references).
///
/// Asset references are kept verbatim in the same markdown form they were
/// written (`![image](fs://…)` / `[audio](fs://…)`), which is exactly what
/// [CardData.assets] stores. The fact text is the remaining content with those
/// markers removed and surrounding whitespace collapsed.
(String, List<String>) _splitFactAndAssets(String content) {
  // Matches both image (`![label](fs://x)`) and audio (`[label](fs://x)`)
  // references; the leading `!` is optional so audio markers match too.
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

String _migrationStatePath(String userId) => p.join(
    FileSystemService.instance.getSystemPath(userId), 'migration_state.json');

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
    String userId, Map<String, dynamic> state) async {
  final path = _migrationStatePath(userId);
  final dir = Directory(p.dirname(path));
  if (!await dir.exists()) await dir.create(recursive: true);

  state['updated_at'] = DateTime.now().toIso8601String();
  const encoder = JsonEncoder.withIndent('  ');
  final tmpFile = File('$path.tmp');
  await tmpFile.writeAsString(encoder.convert(state));
  await tmpFile.rename(path);
}
