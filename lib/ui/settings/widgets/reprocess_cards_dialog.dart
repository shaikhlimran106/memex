import 'package:flutter/material.dart';
import 'package:memex/domain/models/reprocess_cards_options.dart';
import 'package:memex/utils/user_storage.dart';

class ReprocessCardsDebugOptions {
  const ReprocessCardsDebugOptions({
    this.dateFrom,
    this.dateTo,
    this.limit,
    this.reanalyzeAssets = false,
    this.downstreamMode = ReprocessCardsDownstreamMode.cardOnly,
  });

  final DateTime? dateFrom;
  final DateTime? dateTo;
  final int? limit;
  final bool reanalyzeAssets;
  final ReprocessCardsDownstreamMode downstreamMode;

  Map<String, dynamic> toTaskPayload() {
    final payload = <String, dynamic>{
      ReprocessCardsPayloadKeys.downstreamMode: downstreamMode.payloadValue,
    };
    final from = dateFrom;
    if (from != null) {
      payload['date_from'] = _formatDate(from);
    }
    final to = dateTo;
    if (to != null) {
      payload['date_to'] = _formatDate(to);
    }
    final limitValue = limit;
    if (limitValue != null && limitValue > 0) {
      payload['limit'] = limitValue;
    }
    if (reanalyzeAssets) {
      payload['reanalyze_assets'] = true;
    }
    return payload;
  }

  static String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

Future<ReprocessCardsDebugOptions?> showReprocessCardsDialog(
  BuildContext context,
) {
  return showDialog<ReprocessCardsDebugOptions>(
    context: context,
    builder: (context) => const ReprocessCardsDialog(),
  );
}

class ReprocessCardsDialog extends StatefulWidget {
  const ReprocessCardsDialog({super.key});

  @override
  State<ReprocessCardsDialog> createState() => _ReprocessCardsDialogState();
}

class _ReprocessCardsDialogState extends State<ReprocessCardsDialog> {
  DateTime? _dateFrom;
  DateTime? _dateTo;
  int? _limit;
  var _reanalyzeAssets = false;
  var _downstreamMode = ReprocessCardsDownstreamMode.cardOnly;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(UserStorage.l10n.reprocessCards),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(UserStorage.l10n.selectDateRangeOptional),
            const SizedBox(height: 8),
            ListTile(
              title: Text(UserStorage.l10n.startDate),
              trailing: TextButton(
                onPressed: () => _selectStartDate(context),
                child: Text(
                  _dateFrom == null
                      ? UserStorage.l10n.select
                      : ReprocessCardsDebugOptions._formatDate(_dateFrom!),
                ),
              ),
            ),
            ListTile(
              title: Text(UserStorage.l10n.endDate),
              trailing: TextButton(
                onPressed: () => _selectEndDate(context),
                child: Text(
                  _dateTo == null
                      ? UserStorage.l10n.select
                      : ReprocessCardsDebugOptions._formatDate(_dateTo!),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('reprocess_cards_limit_field'),
              decoration: InputDecoration(
                labelText: UserStorage.l10n.processLimitOptional,
                hintText: UserStorage.l10n.leaveEmptyForAll,
              ),
              keyboardType: TextInputType.number,
              onChanged: (value) {
                _limit = int.tryParse(value);
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('reprocess_cards_reanalyze_assets_switch'),
              contentPadding: EdgeInsets.zero,
              value: _reanalyzeAssets,
              title: Text(UserStorage.l10n.reanalyzeMediaAssets),
              subtitle: Text(UserStorage.l10n.reanalyzeMediaAssetsDesc),
              onChanged: (value) {
                setState(() {
                  _reanalyzeAssets = value;
                });
              },
            ),
            const SizedBox(height: 8),
            Text(
              UserStorage.l10n.reprocessCardsDownstreamMode,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            _buildModeTile(
              key: const Key('reprocess_cards_mode_card_only'),
              mode: ReprocessCardsDownstreamMode.cardOnly,
              title: Text(UserStorage.l10n.reprocessCardsCardOnly),
              subtitle: Text(UserStorage.l10n.reprocessCardsCardOnlyDesc),
            ),
            _buildModeTile(
              key: const Key('reprocess_cards_mode_post_card_router'),
              mode: ReprocessCardsDownstreamMode.postCardRouter,
              title: Text(UserStorage.l10n.reprocessCardsRerunDownstream),
              subtitle: Text(
                UserStorage.l10n.reprocessCardsRerunDownstreamDesc,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(UserStorage.l10n.cancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(
              context,
              ReprocessCardsDebugOptions(
                dateFrom: _dateFrom,
                dateTo: _dateTo,
                limit: _limit,
                reanalyzeAssets: _reanalyzeAssets,
                downstreamMode: _downstreamMode,
              ),
            );
          },
          child: Text(UserStorage.l10n.startProcessing),
        ),
      ],
    );
  }

  Future<void> _selectStartDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date == null) return;
    setState(() {
      _dateFrom = date;
      if (_dateTo != null && _dateTo!.isBefore(date)) {
        _dateTo = date;
      }
    });
  }

  Future<void> _selectEndDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTo ?? DateTime.now(),
      firstDate: _dateFrom ?? DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date == null) return;
    setState(() {
      _dateTo = date;
    });
  }

  void _setDownstreamMode(ReprocessCardsDownstreamMode? value) {
    if (value == null) return;
    setState(() {
      _downstreamMode = value;
    });
  }

  Widget _buildModeTile({
    required Key key,
    required ReprocessCardsDownstreamMode mode,
    required Widget title,
    required Widget subtitle,
  }) {
    final selected = _downstreamMode == mode;
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: title,
      subtitle: subtitle,
      onTap: () => _setDownstreamMode(mode),
    );
  }
}
