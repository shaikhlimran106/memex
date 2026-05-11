import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:memex/data/services/global_event_bus.dart';
import 'package:memex/data/services/user_notification_service.dart';
import 'package:memex/domain/models/system_event.dart';
import 'package:memex/utils/logger.dart';

/// Subscribes synchronously to `GlobalEventBus` for `dataChanged` events
/// with `ns == card`, diffs `before` / `after` on `comments` and `insight`,
/// maintains a foreground registry of currently mounted
/// `TimelineCardDetailScreen`s, and translates qualifying changes into
/// upserts / dismisses against [UserNotificationService].
class CardDetailNotifier {
  CardDetailNotifier._({UserNotificationService? notificationService})
      : _notificationService =
            notificationService ?? UserNotificationService.instance;

  static final CardDetailNotifier instance = CardDetailNotifier._();

  /// Creates a testable instance with an injectable [UserNotificationService].
  @visibleForTesting
  factory CardDetailNotifier.forTest({
    required UserNotificationService notificationService,
  }) {
    return CardDetailNotifier._(notificationService: notificationService);
  }

  final Logger _logger = getLogger('CardDetailNotifier');
  final UserNotificationService _notificationService;

  /// Ref-counted foreground registry: factId → count of mounted detail screens.
  final Map<String, int> _foreground = {};

  /// Install sync subscription on `SystemEventTypes.dataChanged`.
  void init() {
    GlobalEventBus.instance.subscribeSync<DataChangeRecord>(
      eventType: SystemEventTypes.dataChanged,
      subscription: EventSyncSubscription<DataChangeRecord>(
        subscriptionId: 'card_detail_notifier',
        handler: _handle,
      ),
    );
  }

  // --- Foreground registry ---

  /// Register a detail screen as viewing [factId]. Ref-counted.
  void registerForeground(String factId) {
    _foreground[factId] = (_foreground[factId] ?? 0) + 1;
  }

  /// Unregister a detail screen for [factId]. Removes entry at zero.
  void unregisterForeground(String factId) {
    final current = (_foreground[factId] ?? 0) - 1;
    if (current <= 0) {
      _foreground.remove(factId);
    } else {
      _foreground[factId] = current;
    }
  }

  /// Whether [factId] is currently being viewed by at least one detail screen.
  bool isForeground(String factId) => (_foreground[factId] ?? 0) > 0;

  // --- Dismiss on viewed ---

  /// Called by `TimelineCardDetailScreen` once `_fetchDetail` finishes.
  Future<void> dismissOnViewed(String userId, String factId) async {
    _logger.fine('dismissOnViewed: userId=$userId, factId=$factId');
    await _notificationService.dismissBy(
      userId: userId,
      notificationType: 'card_detail_update',
      subjectKey: factId,
    );
  }

  // --- Event handling ---

  /// Exposed for testing. In production, called by the sync subscription.
  @visibleForTesting
  Future<void> handleForTest(
      String userId, SystemEvent<DataChangeRecord> e) async {
    await _handle(userId, e);
  }

  Future<void> _handle(String userId, SystemEvent<DataChangeRecord> e) async {
    try {
      final record = e.payload;

      // Only handle card namespace events.
      if (record.ns != DataChangeNs.card) return;

      final factId = record.documentKey;

      // Delete → dismiss any existing notification and return.
      if (record.op == DataChangeOp.delete) {
        _logger.info(
          'Card deleted: factId=$factId — dismissing notification',
        );
        await _notificationService.dismissBy(
          userId: userId,
          notificationType: 'card_detail_update',
          subjectKey: factId,
        );
        return;
      }

      // Compute diff signals.
      final signals = computeSignals(record.before, record.after);
      if (signals.isEmpty) return;

      // Foreground → dismiss (user is already viewing).
      if (isForeground(factId)) {
        _logger.info(
          'Card change: factId=$factId, op=${record.op}, '
          'signals=$signals — foreground, dismissing',
        );
        await _notificationService.dismissBy(
          userId: userId,
          notificationType: 'card_detail_update',
          subjectKey: factId,
        );
        return;
      }

      // Not foreground → read existing row and merge signals.
      final existing = await _notificationService.list(
        userId: userId,
        notificationType: 'card_detail_update',
      );
      final existingRow =
          existing.where((r) => r.subjectKey == factId).toList();

      Set<String> mergedSignals = Set<String>.from(signals);
      if (existingRow.isNotEmpty && existingRow.first.payload != null) {
        try {
          final decoded =
              jsonDecode(existingRow.first.payload!) as Map<String, dynamic>;
          final storedSignals =
              (decoded['signals'] as List?)?.cast<String>().toSet() ?? {};
          mergedSignals = mergedSignals.union(storedSignals);
        } catch (_) {
          // If payload is corrupt, just use the new signals.
        }
      }

      await _notificationService.upsert(
        userId: userId,
        notificationType: 'card_detail_update',
        subjectKey: factId,
        payload: {'signals': mergedSignals.toList()..sort()},
      );

      _logger.info(
        'Card change: factId=$factId, op=${record.op}, '
        'signals=$signals — upserted (merged: $mergedSignals)',
      );
    } catch (e, st) {
      // Swallow all failures — sync subscription must never re-throw.
      _logger.severe('Error handling card change event', e, st);
    }
  }

  // --- Pure diff helper ---

  /// Computes which signal categories changed between [before] and [after].
  /// Returns a subset of `{"comments", "insight"}`.
  @visibleForTesting
  static Set<String> computeSignals(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  ) {
    final b = before ?? <String, dynamic>{};
    final a = after ?? <String, dynamic>{};
    final signals = <String>{};

    // --- Comments diff ---
    if (_commentsDiffer(b, a)) {
      signals.add('comments');
    }

    // --- Insight diff ---
    if (_insightDiffers(b, a)) {
      signals.add('insight');
    }

    return signals;
  }

  /// Compare comments lists. Returns true if they differ.
  static bool _commentsDiffer(
      Map<String, dynamic> before, Map<String, dynamic> after) {
    final beforeComments = before['comments'] as List? ?? [];
    final afterComments = after['comments'] as List? ?? [];

    if (beforeComments.length != afterComments.length) return true;

    for (var i = 0; i < beforeComments.length; i++) {
      final bItem = beforeComments[i] as Map<String, dynamic>? ?? {};
      final aItem = afterComments[i] as Map<String, dynamic>? ?? {};

      if (bItem['id'] != aItem['id'] ||
          bItem['content'] != aItem['content'] ||
          bItem['reply_to_id'] != aItem['reply_to_id'] ||
          bItem['is_ai'] != aItem['is_ai']) {
        return true;
      }
    }

    return false;
  }

  /// Compare insight maps. Returns true if they differ.
  /// Deliberately EXCLUDES `character_id` from the diff.
  static bool _insightDiffers(
      Map<String, dynamic> before, Map<String, dynamic> after) {
    final beforeInsight = before['insight'] as Map<String, dynamic>?;
    final afterInsight = after['insight'] as Map<String, dynamic>?;

    // Both null → no diff.
    if (beforeInsight == null && afterInsight == null) return false;
    // One null, other not → diff.
    if (beforeInsight == null || afterInsight == null) return true;

    // Compare text.
    if (beforeInsight['text'] != afterInsight['text']) return true;

    // Compare summary.
    if (beforeInsight['summary'] != afterInsight['summary']) return true;

    // Compare related_facts by sorted id list.
    final beforeRelated = _sortedRelatedFactIds(beforeInsight);
    final afterRelated = _sortedRelatedFactIds(afterInsight);
    if (!_listEquals(beforeRelated, afterRelated)) return true;

    return false;
  }

  /// Extract and sort related_facts[].id from an insight map.
  static List<String> _sortedRelatedFactIds(Map<String, dynamic> insight) {
    final relatedFacts = insight['related_facts'] as List? ?? [];
    final ids = <String>[];
    for (final fact in relatedFacts) {
      if (fact is Map<String, dynamic> && fact['id'] != null) {
        ids.add(fact['id'].toString());
      }
    }
    ids.sort();
    return ids;
  }

  /// Simple list equality check.
  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
