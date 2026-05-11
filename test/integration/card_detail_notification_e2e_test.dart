import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/card_detail_notifier.dart';
import 'package:memex/data/services/user_notification_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/system_event.dart';

// ---------------------------------------------------------------------------
// Fake UserNotificationService that records all calls for verification.
// ---------------------------------------------------------------------------

/// A testable [UserNotificationService] that stores notifications in memory
/// and records all method calls for assertion.
class FakeUserNotificationService extends UserNotificationService {
  FakeUserNotificationService() : super.forTest();

  final List<Map<String, dynamic>> upsertCalls = [];
  final List<Map<String, dynamic>> dismissByCalls = [];
  final List<String> dismissCalls = [];

  /// In-memory store of notifications keyed by (userId, notificationType, subjectKey).
  final List<UserNotification> _rows = [];
  int _idCounter = 0;

  @override
  Future<String> upsert({
    required String userId,
    required String notificationType,
    required String subjectKey,
    required Map<String, dynamic> payload,
  }) async {
    upsertCalls.add({
      'userId': userId,
      'notificationType': notificationType,
      'subjectKey': subjectKey,
      'payload': payload,
    });

    // Simulate real upsert behavior: find existing or create new.
    final existingIdx = _rows.indexWhere((r) =>
        r.userId == userId &&
        r.notificationType == notificationType &&
        r.subjectKey == subjectKey);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (existingIdx >= 0) {
      final existing = _rows[existingIdx];
      _rows[existingIdx] = UserNotification(
        id: existing.id,
        userId: userId,
        notificationType: notificationType,
        subjectKey: subjectKey,
        payload: jsonEncode(payload),
        createdAt: existing.createdAt,
        updatedAt: now,
      );
      return existing.id;
    }

    final id = 'fake-id-${_idCounter++}';
    _rows.add(UserNotification(
      id: id,
      userId: userId,
      notificationType: notificationType,
      subjectKey: subjectKey,
      payload: jsonEncode(payload),
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  @override
  Future<void> dismiss(String id) async {
    dismissCalls.add(id);
    _rows.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> dismissBy({
    required String userId,
    required String notificationType,
    required String subjectKey,
  }) async {
    dismissByCalls.add({
      'userId': userId,
      'notificationType': notificationType,
      'subjectKey': subjectKey,
    });
    _rows.removeWhere((r) =>
        r.userId == userId &&
        r.notificationType == notificationType &&
        r.subjectKey == subjectKey);
  }

  @override
  Future<List<UserNotification>> list({
    required String userId,
    String? notificationType,
  }) async {
    return _rows.where((r) {
      if (r.userId != userId) return false;
      if (notificationType != null && r.notificationType != notificationType) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Reset all recorded calls (but keep stored rows).
  void resetCalls() {
    upsertCalls.clear();
    dismissByCalls.clear();
    dismissCalls.clear();
  }

  /// Get current row count.
  int get rowCount => _rows.length;
}

void main() {
  group('End-to-end event-to-notification smoke test', () {
    late FakeUserNotificationService fakeService;
    late CardDetailNotifier notifier;

    const userId = 'test-user-1';
    const factId = '2025/01/15.md#ts_3';

    setUp(() {
      fakeService = FakeUserNotificationService();
      notifier = CardDetailNotifier.forTest(
        notificationService: fakeService,
      );
    });

    SystemEvent<DataChangeRecord> makeCardEvent({
      required DataChangeOp op,
      Map<String, dynamic>? before,
      Map<String, dynamic>? after,
      String key = factId,
    }) {
      return SystemEvent<DataChangeRecord>(
        type: SystemEventTypes.dataChanged,
        source: 'file_system_service',
        payload: DataChangeRecord(
          op: op,
          ns: DataChangeNs.card,
          documentKey: key,
          before: before,
          after: after,
        ),
      );
    }

    test(
        'card change with comments diff → one row lands in notifications '
        'with expected payload', () async {
      // Simulate a card update where comments changed.
      final event = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'title': 'My Card',
          'comments': <dynamic>[],
          'insight': null,
        },
        after: {
          'fact_id': factId,
          'title': 'My Card',
          'comments': [
            {
              'id': 'comment-1',
              'content': 'AI generated comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': null,
        },
      );

      await notifier.handleForTest(userId, event);

      // Verify upsert was called exactly once.
      expect(fakeService.upsertCalls, hasLength(1));

      final call = fakeService.upsertCalls.first;
      expect(call['userId'], userId);
      expect(call['notificationType'], 'card_detail_update');
      expect(call['subjectKey'], factId);

      final payload = call['payload'] as Map<String, dynamic>;
      expect(payload['signals'], contains('comments'));

      // Verify one row exists in the fake store.
      final rows = await fakeService.list(
        userId: userId,
        notificationType: 'card_detail_update',
      );
      expect(rows, hasLength(1));
      expect(rows.first.subjectKey, factId);
    });

    test(
        'register factId as foreground → simulate another event → '
        'verify dismissBy was called (no upsert)', () async {
      // First, create an initial notification (user not viewing).
      final event1 = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'comments': <dynamic>[],
        },
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'first comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
      );
      await notifier.handleForTest(userId, event1);

      // Verify initial notification was created.
      expect(fakeService.upsertCalls, hasLength(1));
      expect(fakeService.rowCount, 1);

      // Now register the factId as foreground (user opens detail page).
      notifier.registerForeground(factId);
      fakeService.resetCalls();

      // Simulate another card change while user is viewing.
      final event2 = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'first comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'first comment',
              'reply_to_id': null,
              'is_ai': true,
            },
            {
              'id': 'c2',
              'content': 'second comment',
              'reply_to_id': null,
              'is_ai': true,
            },
          ],
        },
      );
      await notifier.handleForTest(userId, event2);

      // Verify: dismissBy was called (foreground suppression), no upsert.
      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.dismissByCalls.first['subjectKey'], factId);
      expect(fakeService.upsertCalls, isEmpty);

      // The existing row should have been dismissed.
      expect(fakeService.rowCount, 0);

      // Cleanup.
      notifier.unregisterForeground(factId);
    });

    test('delete event → verify dismissBy was called', () async {
      // First, create a notification for the card.
      final createEvent = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'comments': <dynamic>[],
        },
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'a comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
      );
      await notifier.handleForTest(userId, createEvent);

      // Verify notification exists.
      expect(fakeService.rowCount, 1);
      fakeService.resetCalls();

      // Now simulate a delete event for the card.
      final deleteEvent = makeCardEvent(
        op: DataChangeOp.delete,
        before: {
          'fact_id': factId,
          'title': 'Deleted Card',
          'comments': [
            {
              'id': 'c1',
              'content': 'a comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
        after: null,
      );
      await notifier.handleForTest(userId, deleteEvent);

      // Verify: dismissBy was called for the delete.
      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.dismissByCalls.first['subjectKey'], factId);
      expect(fakeService.dismissByCalls.first['notificationType'],
          'card_detail_update');

      // No upsert should have been called.
      expect(fakeService.upsertCalls, isEmpty);

      // The row should be gone.
      expect(fakeService.rowCount, 0);
    });

    test('full lifecycle: create → foreground suppress → delete cleanup',
        () async {
      // Step 1: Card update while user is NOT viewing → notification created.
      final event1 = makeCardEvent(
        op: DataChangeOp.update,
        before: {'fact_id': factId, 'comments': <dynamic>[]},
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'new comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
      );
      await notifier.handleForTest(userId, event1);
      expect(fakeService.rowCount, 1);
      expect(fakeService.upsertCalls, hasLength(1));

      // Step 2: User opens detail page → register foreground.
      notifier.registerForeground(factId);
      fakeService.resetCalls();

      // Step 3: Another update while foreground → dismiss, no new notification.
      final event2 = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'new comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': null,
        },
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'new comment',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': {
            'text': 'New insight generated',
            'summary': 'Summary',
            'related_facts': <dynamic>[],
          },
        },
      );
      await notifier.handleForTest(userId, event2);
      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.upsertCalls, isEmpty);
      expect(fakeService.rowCount, 0);

      // Step 4: User leaves detail page.
      notifier.unregisterForeground(factId);
      fakeService.resetCalls();

      // Step 5: Another update while NOT foreground → new notification.
      final event3 = makeCardEvent(
        op: DataChangeOp.insert,
        before: null,
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'comment on new card',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': {
            'text': 'Insight text',
            'summary': 'Summary',
            'related_facts': <dynamic>[],
          },
        },
      );
      await notifier.handleForTest(userId, event3);
      expect(fakeService.upsertCalls, hasLength(1));
      expect(fakeService.rowCount, 1);

      // Verify payload has both signals.
      final payload =
          fakeService.upsertCalls.first['payload'] as Map<String, dynamic>;
      final signals = (payload['signals'] as List).toSet();
      expect(signals, containsAll(['comments', 'insight']));

      fakeService.resetCalls();

      // Step 6: Card deleted → notification dismissed.
      final deleteEvent = makeCardEvent(
        op: DataChangeOp.delete,
        before: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'comment on new card',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
        after: null,
      );
      await notifier.handleForTest(userId, deleteEvent);
      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.rowCount, 0);
    });

    test('non-card namespace events are ignored', () async {
      final pkmEvent = SystemEvent<DataChangeRecord>(
        type: SystemEventTypes.dataChanged,
        source: 'search_service',
        payload: DataChangeRecord(
          op: DataChangeOp.update,
          ns: DataChangeNs.pkmFile,
          documentKey: 'some/file.md',
          before: {'content': 'old'},
          after: {'content': 'new'},
        ),
      );

      await notifier.handleForTest(userId, pkmEvent);

      expect(fakeService.upsertCalls, isEmpty);
      expect(fakeService.dismissByCalls, isEmpty);
    });

    test('update with no relevant diff (only title change) → no notification',
        () async {
      final event = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'title': 'Old Title',
          'comments': [
            {
              'id': 'c1',
              'content': 'same',
              'reply_to_id': null,
              'is_ai': false,
            }
          ],
          'insight': {
            'text': 'same insight',
            'summary': 'same summary',
            'related_facts': <dynamic>[],
          },
        },
        after: {
          'fact_id': factId,
          'title': 'New Title',
          'comments': [
            {
              'id': 'c1',
              'content': 'same',
              'reply_to_id': null,
              'is_ai': false,
            }
          ],
          'insight': {
            'text': 'same insight',
            'summary': 'same summary',
            'related_facts': <dynamic>[],
          },
        },
      );

      await notifier.handleForTest(userId, event);

      expect(fakeService.upsertCalls, isEmpty);
      expect(fakeService.dismissByCalls, isEmpty);
    });

    test('signal merge: comments then insight → merged payload', () async {
      // First event: comments change.
      final event1 = makeCardEvent(
        op: DataChangeOp.update,
        before: {'fact_id': factId, 'comments': <dynamic>[]},
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'hello',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
        },
      );
      await notifier.handleForTest(userId, event1);

      expect(fakeService.upsertCalls, hasLength(1));
      var payload =
          fakeService.upsertCalls.last['payload'] as Map<String, dynamic>;
      expect((payload['signals'] as List).toSet(), {'comments'});

      // Second event: insight change (comments unchanged).
      final event2 = makeCardEvent(
        op: DataChangeOp.update,
        before: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'hello',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': null,
        },
        after: {
          'fact_id': factId,
          'comments': [
            {
              'id': 'c1',
              'content': 'hello',
              'reply_to_id': null,
              'is_ai': true,
            }
          ],
          'insight': {
            'text': 'New insight',
            'summary': 'Summary',
            'related_facts': <dynamic>[],
          },
        },
      );
      await notifier.handleForTest(userId, event2);

      // Second upsert should have merged signals.
      expect(fakeService.upsertCalls, hasLength(2));
      payload = fakeService.upsertCalls.last['payload'] as Map<String, dynamic>;
      expect((payload['signals'] as List).toSet(), {'comments', 'insight'});

      // Still only one row in the store.
      expect(fakeService.rowCount, 1);
    });
  });
}
