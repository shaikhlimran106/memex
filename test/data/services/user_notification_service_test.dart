import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/db/tables.dart';
import 'package:memex/data/services/user_notification_service.dart';

part 'user_notification_service_test.g.dart';

/// Minimal Drift database for testing UserNotificationService in isolation.
@DriftDatabase(tables: [UserNotifications])
class TestNotificationServiceDb extends _$TestNotificationServiceDb {
  TestNotificationServiceDb(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_unique '
              'ON user_notifications(user_id, notification_type, subject_key)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_user_notifications_list '
              'ON user_notifications(user_id, notification_type, updated_at)');
        },
      );
}

/// A testable helper that mirrors [UserNotificationService] logic but uses
/// a provided [TestNotificationServiceDb] instead of the global singleton.
class TestableNotificationService {
  TestableNotificationService(this._db);

  final TestNotificationServiceDb _db;

  Future<String> upsert({
    required String userId,
    required String notificationType,
    required String subjectKey,
    required Map<String, dynamic> payload,
  }) async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.userNotifications)
            ..where((t) =>
                t.userId.equals(userId) &
                t.notificationType.equals(notificationType) &
                t.subjectKey.equals(subjectKey)))
          .getSingleOrNull();

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      if (existing != null) {
        await (_db.update(_db.userNotifications)
              ..where((t) => t.id.equals(existing.id)))
            .write(UserNotificationsCompanion(
          payload: Value(jsonEncode(payload)),
          updatedAt: Value(now),
        ));
        return existing.id;
      }

      final id = 'test-${DateTime.now().microsecondsSinceEpoch}';
      await _db.into(_db.userNotifications).insert(
            UserNotificationsCompanion.insert(
              id: id,
              userId: userId,
              notificationType: notificationType,
              subjectKey: subjectKey,
              payload: Value(jsonEncode(payload)),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return id;
    });
  }

  Future<void> dismiss(String id) async {
    await (_db.delete(_db.userNotifications)..where((t) => t.id.equals(id)))
        .go();
  }

  Future<void> dismissBy({
    required String userId,
    required String notificationType,
    required String subjectKey,
  }) async {
    await (_db.delete(_db.userNotifications)
          ..where((t) =>
              t.userId.equals(userId) &
              t.notificationType.equals(notificationType) &
              t.subjectKey.equals(subjectKey)))
        .go();
  }

  Future<List<UserNotification>> list({
    required String userId,
    String? notificationType,
  }) async {
    final query = _db.select(_db.userNotifications)
      ..where((t) {
        var condition = t.userId.equals(userId);
        if (notificationType != null) {
          condition = condition & t.notificationType.equals(notificationType);
        }
        return condition;
      })
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);

    return query.get();
  }
}

void main() {
  late TestNotificationServiceDb db;
  late TestableNotificationService service;

  setUp(() {
    db = TestNotificationServiceDb(NativeDatabase.memory());
    service = TestableNotificationService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('UserNotificationService', () {
    group('upsert', () {
      test('first upsert inserts a new row', () async {
        final id = await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-123',
          payload: {
            'signals': ['comments']
          },
        );

        expect(id, isNotEmpty);

        final rows = await service.list(userId: 'user-a');
        expect(rows, hasLength(1));
        expect(rows.first.id, id);
        expect(rows.first.userId, 'user-a');
        expect(rows.first.notificationType, 'card_detail_update');
        expect(rows.first.subjectKey, 'fact-123');

        final decoded = jsonDecode(rows.first.payload!) as Map<String, dynamic>;
        expect(decoded['signals'], ['comments']);
      });

      test(
          'second upsert with same triple updates in place, bumps updatedAt, '
          'does NOT add a row', () async {
        final id1 = await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-123',
          payload: {
            'signals': ['comments']
          },
        );

        // Small delay to ensure updatedAt differs
        await Future<void>.delayed(const Duration(seconds: 1));

        final id2 = await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-123',
          payload: {
            'signals': ['comments', 'insight']
          },
        );

        // Same row id returned
        expect(id2, id1);

        // Still only one row
        final rows = await service.list(userId: 'user-a');
        expect(rows, hasLength(1));

        // Payload updated
        final decoded = jsonDecode(rows.first.payload!) as Map<String, dynamic>;
        expect(
          (decoded['signals'] as List).toSet(),
          {'comments', 'insight'},
        );

        // updatedAt should be > createdAt (we waited 1 second)
        expect(rows.first.updatedAt, greaterThan(rows.first.createdAt));
      });
    });

    group('dismiss', () {
      test('dismiss(id) deletes exactly one row', () async {
        final id1 = await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
          payload: {
            'signals': ['comments']
          },
        );
        await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-2',
          payload: {
            'signals': ['insight']
          },
        );

        await service.dismiss(id1);

        final rows = await service.list(userId: 'user-a');
        expect(rows, hasLength(1));
        expect(rows.first.subjectKey, 'fact-2');
      });

      test('dismissBy(triple) deletes exactly one row', () async {
        await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
          payload: {
            'signals': ['comments']
          },
        );
        await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-2',
          payload: {
            'signals': ['insight']
          },
        );

        await service.dismissBy(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
        );

        final rows = await service.list(userId: 'user-a');
        expect(rows, hasLength(1));
        expect(rows.first.subjectKey, 'fact-2');
      });
    });

    group('list', () {
      test('list(userA) never returns userB rows', () async {
        await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
          payload: {
            'signals': ['comments']
          },
        );
        await service.upsert(
          userId: 'user-b',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-2',
          payload: {
            'signals': ['insight']
          },
        );

        final rowsA = await service.list(userId: 'user-a');
        expect(rowsA, hasLength(1));
        expect(rowsA.first.subjectKey, 'fact-1');

        final rowsB = await service.list(userId: 'user-b');
        expect(rowsB, hasLength(1));
        expect(rowsB.first.subjectKey, 'fact-2');
      });

      test('list with notificationType filter works', () async {
        await service.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
          payload: {
            'signals': ['comments']
          },
        );
        // Simulate a different notification type (future use)
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await db.into(db.userNotifications).insert(
              UserNotificationsCompanion.insert(
                id: 'other-type-id',
                userId: 'user-a',
                notificationType: 'task_failed',
                subjectKey: 'task-xyz',
                payload: const Value('{}'),
                createdAt: now,
                updatedAt: now,
              ),
            );

        final filtered = await service.list(
          userId: 'user-a',
          notificationType: 'card_detail_update',
        );
        expect(filtered, hasLength(1));
        expect(filtered.first.notificationType, 'card_detail_update');

        final all = await service.list(userId: 'user-a');
        expect(all, hasLength(2));
      });
    });

    group('AppDatabase.isInitialized guard', () {
      test('service methods return sentinels when DB is not initialized',
          () async {
        // AppDatabase.isInitialized is a static getter on the real AppDatabase.
        // When _instance is null, it returns false. We verify the real service
        // handles this by checking the static directly.
        expect(AppDatabase.isInitialized, isFalse,
            reason:
                'No AppDatabase.init() was called, so isInitialized should be false');

        // The real singleton service should return sentinels without throwing.
        final realService = UserNotificationService.instance;

        final id = await realService.upsert(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
          payload: {
            'signals': ['comments']
          },
        );
        expect(id, isEmpty);

        // dismiss and dismissBy should not throw
        await realService.dismiss('nonexistent');
        await realService.dismissBy(
          userId: 'user-a',
          notificationType: 'card_detail_update',
          subjectKey: 'fact-1',
        );

        final rows = await realService.list(userId: 'user-a');
        expect(rows, isEmpty);
      });
    });
  });
}
