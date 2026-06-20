import 'package:memex/data/services/card_renderer.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/domain/models/card_detail_model.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/domain/models/system_event.dart';
import 'package:memex/utils/logger.dart';

final _logger = getLogger('TimelineCardChangeHandler');

Future<void> handleTimelineCardChanged(
  String userId,
  SystemEvent<DataChangeRecord> event,
) async {
  final record = event.payload;
  if (record.ns != DataChangeNs.card || record.after == null) return;

  try {
    final before = _cardFromJson(record.before);
    final after = CardData.fromJson(record.after!);
    if (after.deleted == true) return;

    final renderResult = await renderCard(
      userId: userId,
      cardData: after,
      factContent: after.fact,
    );
    final assetsAndText = await extractAssetsAndRawText(userId, after);
    final assets = (assetsAndText['assets'] as List<AssetData>)
        .map((asset) => asset.toJson())
        .toList();
    final rawText = assetsAndText['rawText'] as String?;

    final isTimelineInsert = record.op == DataChangeOp.insert ||
        before == null ||
        (before.status != 'completed' && after.status == 'completed');

    if (isTimelineInsert) {
      EventBusService.instance.emitEvent(
        CardAddedMessage(
          id: record.documentKey,
          html: renderResult.html ?? '',
          timestamp: after.timestamp,
          tags: after.tags,
          status: renderResult.status,
          title: after.title,
          uiConfigs: renderResult.uiConfigs,
          assets: assets.isEmpty ? null : assets,
          rawText: rawText,
          address: after.address,
        ),
      );
      return;
    }

    EventBusService.instance.emitEvent(
      CardUpdatedMessage(
        id: record.documentKey,
        html: renderResult.html ?? '',
        timestamp: after.timestamp,
        tags: after.tags,
        status: renderResult.status,
        title: after.title,
        uiConfigs: renderResult.uiConfigs,
        assets: assets.isEmpty ? null : assets,
        rawText: rawText,
        address: after.address,
        failureReason: after.failureReason,
      ),
    );
  } catch (e, st) {
    _logger.warning(
      'Failed to emit timeline card event for ${record.documentKey}',
      e,
      st,
    );
  }
}

CardData? _cardFromJson(Map<String, dynamic>? json) {
  if (json == null) return null;
  return CardData.fromJson(json);
}
