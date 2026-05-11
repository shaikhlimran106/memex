import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/ui/timeline/widgets/timeline_card_detail_screen.dart';
import 'package:memex/utils/user_storage.dart';

/// Renders a card-detail notification in the Action Center.
///
/// Shows a compact row indicating new comments/insight on a card.
/// Tapping dismisses the notification, closes the Action Center, and
/// navigates to the card detail screen.
class CardDetailNotificationWidget extends StatefulWidget {
  const CardDetailNotificationWidget({
    super.key,
    required this.notification,
  });

  final UserNotification notification;

  @override
  State<CardDetailNotificationWidget> createState() =>
      _CardDetailNotificationWidgetState();
}

class _CardDetailNotificationWidgetState
    extends State<CardDetailNotificationWidget> {
  late final MemexRouter _router;
  CardData? _cardData;
  bool _isLoading = true;
  bool _isStale = false;

  @override
  void initState() {
    super.initState();
    _router = MemexRouter();
    _resolveCard();
  }

  Future<void> _resolveCard() async {
    final cardData = await _router.resolveCardForNotification(
      widget.notification.subjectKey,
    );

    if (!mounted) return;

    if (cardData == null) {
      // Card no longer exists — dismiss the stale notification.
      await _router.dismissNotification(widget.notification.id);
      setState(() {
        _isLoading = false;
        _isStale = true;
      });
      return;
    }

    setState(() {
      _cardData = cardData;
      _isLoading = false;
    });
  }

  String _buildDescription() {
    final payload = widget.notification.payload;
    if (payload == null) return '';

    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      final signals =
          (decoded['signals'] as List?)?.cast<String>().toSet() ?? {};

      final l10n = UserStorage.l10n;
      if (signals.contains('comments') && signals.contains('insight')) {
        return l10n.cdnSignalsBoth;
      } else if (signals.contains('comments')) {
        return l10n.cdnSignalsComments;
      } else if (signals.contains('insight')) {
        return l10n.cdnSignalsInsight;
      }
    } catch (_) {}
    return '';
  }

  String _relativeTime() {
    final updatedAt = widget.notification.updatedAt;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final diff = now - updatedAt;

    if (diff < 60) return '${diff}s';
    if (diff < 3600) return '${diff ~/ 60}m';
    if (diff < 86400) return '${diff ~/ 3600}h';
    return '${diff ~/ 86400}d';
  }

  Future<void> _handleTap() async {
    final factId = widget.notification.subjectKey;

    // Dismiss first.
    await _router.dismissNotification(widget.notification.id);

    if (!mounted) return;

    // Close the Action Center sheet.
    Navigator.pop(context);

    // Navigate to card detail.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TimelineCardDetailScreen(cardId: factId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isStale) return const SizedBox.shrink();
    if (_isLoading) return _buildSkeleton(context);

    final title = _cardData?.title?.isNotEmpty == true
        ? _cardData!.title!
        : UserStorage.l10n.untitledCard;
    final description = _buildDescription();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: InkWell(
        onTap: _handleTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.notifications_none_rounded,
                  size: 18,
                  color: Color(0xFF6366F1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _relativeTime(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 12,
                  width: 120,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 80,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
