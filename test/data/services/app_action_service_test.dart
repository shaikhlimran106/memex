import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/app_action_service.dart';

void main() {
  late DateTime now;
  late AppActionService service;

  setUp(() {
    now = DateTime(2026, 6, 16, 10);
    service = AppActionService.test(now: () => now);
  });

  tearDown(() {
    service.dispose();
  });

  group('AppActionService', () {
    test('dispatches a supported quick_note action', () async {
      service.attach();
      final event = expectLater(
        service.actionStream,
        emits(AppActionService.quickNoteAction),
      );

      service.handleAction(AppActionService.quickNoteAction);
      expect(service.consumeIfPending(), AppActionService.quickNoteAction);
      await event;
    });

    test(
      'consumePendingAction returns null when no action is queued',
      () async {
        service.attach();

        final action = await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        );

        expect(action, isNull);
      },
    );

    test('queues a cold-start action before a listener attaches', () async {
      service.handleAction(AppActionService.quickNoteAction);

      service.attach();

      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        AppActionService.quickNoteAction,
      );
    });

    test(
      'waits for a pending action that arrives after consumption starts',
      () async {
        service.attach();
        final pending = service.consumePendingAction(
          timeout: const Duration(milliseconds: 50),
        );

        service.handleAction(AppActionService.quickNoteAction);

        expect(await pending, AppActionService.quickNoteAction);
      },
    );

    test('consumePendingAction is idempotent after one consume', () async {
      service.attach();
      service.handleAction(AppActionService.quickNoteAction);

      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        AppActionService.quickNoteAction,
      );
      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        isNull,
      );
    });

    test('deduplicates re-delivered action after consumption', () async {
      service.attach();
      service.handleAction(AppActionService.quickNoteAction);
      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        AppActionService.quickNoteAction,
      );

      service.handleAction(AppActionService.quickNoteAction);

      expect(service.consumeIfPending(), isNull);
    });

    test('allows the same action again after resetConsumed', () async {
      service.attach();
      service.handleAction(AppActionService.quickNoteAction);
      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        AppActionService.quickNoteAction,
      );

      service.resetConsumed();
      service.handleAction(AppActionService.quickNoteAction);

      expect(service.consumeIfPending(), AppActionService.quickNoteAction);
    });

    test('allows the same action again after the dedup window', () async {
      service.attach();
      service.handleAction(AppActionService.quickNoteAction);
      expect(
        await service.consumePendingAction(
          timeout: const Duration(milliseconds: 1),
        ),
        AppActionService.quickNoteAction,
      );

      now = now.add(const Duration(seconds: 3));
      service.handleAction(AppActionService.quickNoteAction);

      expect(service.consumeIfPending(), AppActionService.quickNoteAction);
    });

    test('ignores unknown action types safely', () {
      service.attach();

      service.handleAction('unknown_action');

      expect(service.consumeIfPending(), isNull);
      expect(service.hasPendingAction, isFalse);
    });

    test('maps memex://quick_note deep link to quick_note action', () {
      service.attach();

      expect(service.handleDeepLink('memex://quick_note'), isTrue);

      expect(service.consumeIfPending(), AppActionService.quickNoteAction);
    });

    test('also accepts path-style memex:///quick_note deep link', () {
      service.attach();

      expect(service.handleDeepLink('memex:///quick_note'), isTrue);

      expect(service.consumeIfPending(), AppActionService.quickNoteAction);
    });

    test('ignores unknown deep link actions safely', () {
      service.attach();

      expect(service.handleDeepLink('memex://unknown_action'), isFalse);
      expect(service.handleDeepLink('https://example.com/quick_note'), isFalse);

      expect(service.consumeIfPending(), isNull);
      expect(service.hasPendingAction, isFalse);
    });
  });
}
