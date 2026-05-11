import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/card_detail_notifier.dart';
import 'package:memex/data/services/user_notification_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/domain/models/system_event.dart';

// ---------------------------------------------------------------------------
// Fake UserNotificationService for testing _handle branches
// ---------------------------------------------------------------------------

/// Records calls to [upsert] and [dismissBy] for verification.
class FakeUserNotificationService extends UserNotificationService {
  FakeUserNotificationService() : super.forTest();

  final List<Map<String, dynamic>> upsertCalls = [];
  final List<Map<String, dynamic>> dismissByCalls = [];
  final List<UserNotification> _rows = [];

  void seedRow(UserNotification row) {
    _rows.add(row);
  }

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
    return 'fake-id';
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
}

void main() {
  // =========================================================================
  // Task 4.5: Unit tests for computeSignals
  // =========================================================================
  group('CardDetailNotifier.computeSignals', () {
    test('comments list length +1 triggers "comments" signal', () {
      final before = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };
      final after = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false},
          {'id': 'c2', 'content': 'world', 'reply_to_id': null, 'is_ai': true},
        ],
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, contains('comments'));
    });

    test('comments list length -1 triggers "comments" signal', () {
      final before = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false},
          {'id': 'c2', 'content': 'world', 'reply_to_id': null, 'is_ai': true},
        ],
      };
      final after = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, contains('comments'));
    });

    test('comment content change triggers "comments" signal', () {
      final before = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };
      final after = {
        'comments': [
          {
            'id': 'c1',
            'content': 'hello updated',
            'reply_to_id': null,
            'is_ai': false
          }
        ],
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, contains('comments'));
    });

    test('null before (insert) with comments triggers "comments" signal', () {
      final after = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };

      final signals = CardDetailNotifier.computeSignals(null, after);
      expect(signals, contains('comments'));
    });

    test('null after (delete) with comments in before triggers "comments"', () {
      final before = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };

      final signals = CardDetailNotifier.computeSignals(before, null);
      expect(signals, contains('comments'));
    });

    test('identical comments produce no "comments" signal', () {
      final data = {
        'comments': [
          {'id': 'c1', 'content': 'hello', 'reply_to_id': null, 'is_ai': false}
        ],
      };

      final signals = CardDetailNotifier.computeSignals(data, Map.from(data));
      expect(signals, isNot(contains('comments')));
    });

    test('insight text change triggers "insight" signal', () {
      final before = {
        'insight': {
          'text': 'old insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
          'character_id': 'char-1',
        },
      };
      final after = {
        'insight': {
          'text': 'new insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
          'character_id': 'char-1',
        },
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, contains('insight'));
    });

    test('insight summary change triggers "insight" signal', () {
      final before = {
        'insight': {
          'text': 'insight',
          'summary': 'old summary',
          'related_facts': <dynamic>[],
        },
      };
      final after = {
        'insight': {
          'text': 'insight',
          'summary': 'new summary',
          'related_facts': <dynamic>[],
        },
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, contains('insight'));
    });

    test('insight related_facts reorder does NOT trigger (sorted comparison)',
        () {
      final before = {
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': [
            {'id': 'fact-b'},
            {'id': 'fact-a'},
          ],
        },
      };
      final after = {
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': [
            {'id': 'fact-a'},
            {'id': 'fact-b'},
          ],
        },
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, isNot(contains('insight')));
    });

    test('insight character_id change does NOT trigger "insight" signal', () {
      final before = {
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
          'character_id': 'char-1',
        },
      };
      final after = {
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
          'character_id': 'char-2',
        },
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, isNot(contains('insight')));
    });

    test(
        'unrelated field-only mutations (title, tags, address, user_fixed_*) '
        'return empty set', () {
      final before = {
        'title': 'Old Title',
        'tags': ['tag1'],
        'address': '123 Main St',
        'user_fixed_title': 'fixed',
        'comments': [
          {'id': 'c1', 'content': 'hi', 'reply_to_id': null, 'is_ai': false}
        ],
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
        },
      };
      final after = {
        'title': 'New Title',
        'tags': ['tag1', 'tag2'],
        'address': '456 Oak Ave',
        'user_fixed_title': 'changed',
        'comments': [
          {'id': 'c1', 'content': 'hi', 'reply_to_id': null, 'is_ai': false}
        ],
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
        },
      };

      final signals = CardDetailNotifier.computeSignals(before, after);
      expect(signals, isEmpty);
    });

    test('both null before and after returns empty set', () {
      final signals = CardDetailNotifier.computeSignals(null, null);
      expect(signals, isEmpty);
    });
  });

  // =========================================================================
  // Task 4.6: Unit tests for _handle branches
  // =========================================================================
  group('CardDetailNotifier._handle branches', () {
    late FakeUserNotificationService fakeService;
    late CardDetailNotifier notifier;

    setUp(() {
      fakeService = FakeUserNotificationService();
      notifier = CardDetailNotifier.forTest(
        notificationService: fakeService,
      );
    });

    SystemEvent<DataChangeRecord> makeEvent({
      required DataChangeOp op,
      String ns = 'card',
      String documentKey = 'fact-123',
      Map<String, dynamic>? before,
      Map<String, dynamic>? after,
    }) {
      return SystemEvent<DataChangeRecord>(
        type: SystemEventTypes.dataChanged,
        source: 'test',
        payload: DataChangeRecord(
          op: op,
          ns: ns,
          documentKey: documentKey,
          before: before,
          after: after,
        ),
      );
    }

    test('delete op → exactly one dismissBy, zero upsert', () async {
      final event = makeEvent(
        op: DataChangeOp.delete,
        before: {
          'comments': [
            {'id': 'c1', 'content': 'hi', 'reply_to_id': null, 'is_ai': false}
          ]
        },
        after: null,
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.dismissByCalls.first['subjectKey'], 'fact-123');
      expect(fakeService.upsertCalls, isEmpty);
    });

    test('empty-diff update → zero writes', () async {
      final data = {
        'title': 'Same Title',
        'comments': [
          {'id': 'c1', 'content': 'hi', 'reply_to_id': null, 'is_ai': false}
        ],
        'insight': {
          'text': 'insight',
          'summary': 'summary',
          'related_facts': <dynamic>[],
        },
      };

      final event = makeEvent(
        op: DataChangeOp.update,
        before: data,
        after: {
          ...data,
          'title': 'Changed Title', // only unrelated field changed
        },
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.dismissByCalls, isEmpty);
      expect(fakeService.upsertCalls, isEmpty);
    });

    test('foreground factId + non-empty diff → dismissBy only', () async {
      notifier.registerForeground('fact-123');

      final event = makeEvent(
        op: DataChangeOp.update,
        before: {'comments': <dynamic>[]},
        after: {
          'comments': [
            {'id': 'c1', 'content': 'new', 'reply_to_id': null, 'is_ai': true}
          ]
        },
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.dismissByCalls, hasLength(1));
      expect(fakeService.upsertCalls, isEmpty);

      notifier.unregisterForeground('fact-123');
    });

    test(
        'non-foreground + non-empty diff with no existing row → '
        'upsert with the computed signals', () async {
      final event = makeEvent(
        op: DataChangeOp.update,
        before: {'comments': <dynamic>[]},
        after: {
          'comments': [
            {'id': 'c1', 'content': 'new', 'reply_to_id': null, 'is_ai': true}
          ]
        },
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.upsertCalls, hasLength(1));
      final call = fakeService.upsertCalls.first;
      expect(call['userId'], 'user-1');
      expect(call['notificationType'], 'card_detail_update');
      expect(call['subjectKey'], 'fact-123');
      final payload = call['payload'] as Map<String, dynamic>;
      expect((payload['signals'] as List).toSet(), {'comments'});
      expect(fakeService.dismissByCalls, isEmpty);
    });

    test(
        'non-foreground + non-empty diff with an existing row → '
        'upsert with set-union of stored and new signals', () async {
      // Seed an existing row with 'insight' signal.
      fakeService.seedRow(UserNotification(
        id: 'existing-id',
        userId: 'user-1',
        notificationType: 'card_detail_update',
        subjectKey: 'fact-123',
        payload: jsonEncode({
          'signals': ['insight']
        }),
        createdAt: 1000,
        updatedAt: 1000,
      ));

      // Event that triggers 'comments' signal.
      final event = makeEvent(
        op: DataChangeOp.update,
        before: {'comments': <dynamic>[]},
        after: {
          'comments': [
            {'id': 'c1', 'content': 'new', 'reply_to_id': null, 'is_ai': true}
          ]
        },
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.upsertCalls, hasLength(1));
      final call = fakeService.upsertCalls.first;
      final payload = call['payload'] as Map<String, dynamic>;
      // Should be union of existing 'insight' + new 'comments'
      expect((payload['signals'] as List).toSet(), {'comments', 'insight'});
    });

    test('non-card namespace event is ignored', () async {
      final event = SystemEvent<DataChangeRecord>(
        type: SystemEventTypes.dataChanged,
        source: 'test',
        payload: DataChangeRecord(
          op: DataChangeOp.update,
          ns: DataChangeNs.pkmFile,
          documentKey: 'some-file',
          before: {'comments': <dynamic>[]},
          after: {
            'comments': [
              {'id': 'c1', 'content': 'new', 'reply_to_id': null, 'is_ai': true}
            ]
          },
        ),
      );

      await notifier.handleForTest('user-1', event);

      expect(fakeService.dismissByCalls, isEmpty);
      expect(fakeService.upsertCalls, isEmpty);
    });
  });
}
