import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/app_action_link_service.dart';
import 'package:memex/data/services/app_action_service.dart';

void main() {
  group('AppActionLinkService', () {
    late AppActionService actionService;

    setUp(() {
      actionService = AppActionService.test();
      actionService.attach();
    });

    tearDown(() {
      actionService.dispose();
    });

    test('consumes and clears an initial quick note link once', () async {
      var readCount = 0;
      var clearCount = 0;
      final service = AppActionLinkService.forTesting(
        isSupportedPlatform: () => true,
        readInitialLink: () async {
          readCount++;
          return 'memex://quick_note';
        },
        clearInitialLink: () async {
          clearCount++;
        },
        eventStream: () => const Stream.empty(),
      );

      await service.initialize(actionService: actionService);
      await service.initialize(actionService: actionService);

      expect(readCount, 1);
      expect(clearCount, 1);
      expect(
        actionService.consumeIfPending(),
        AppActionService.quickNoteAction,
      );
      await service.dispose();
    });

    test('forwards event stream links and ignores empty non-string events',
        () async {
      final controller = StreamController<dynamic>();
      final service = AppActionLinkService.forTesting(
        isSupportedPlatform: () => true,
        readInitialLink: () async => null,
        clearInitialLink: () async {},
        eventStream: () => controller.stream,
      );

      await service.initialize(actionService: actionService);
      controller.add('');
      controller.add(42);
      controller.add('memex://quick_note');
      await pumpEventQueue();

      expect(
        actionService.consumeIfPending(),
        AppActionService.quickNoteAction,
      );

      await service.dispose();
      await controller.close();
    });

    test('tolerates MissingPluginException from initial link bridge', () async {
      var clearCount = 0;
      final service = AppActionLinkService.forTesting(
        isSupportedPlatform: () => true,
        readInitialLink: () => throw MissingPluginException('no bridge'),
        clearInitialLink: () async {
          clearCount++;
        },
        eventStream: () => const Stream.empty(),
      );

      await service.initialize(actionService: actionService);

      expect(clearCount, 0);
      expect(actionService.consumeIfPending(), isNull);
      await service.dispose();
    });

    test('dispose cancels event subscription and allows reinitialize',
        () async {
      final firstController = StreamController<dynamic>();
      final secondController = StreamController<dynamic>();
      var streamCount = 0;
      final service = AppActionLinkService.forTesting(
        isSupportedPlatform: () => true,
        readInitialLink: () async => null,
        clearInitialLink: () async {},
        eventStream: () {
          streamCount++;
          return streamCount == 1
              ? firstController.stream
              : secondController.stream;
        },
      );

      await service.initialize(actionService: actionService);
      await service.dispose();
      firstController.add('memex://quick_note');
      await pumpEventQueue();
      expect(actionService.consumeIfPending(), isNull);

      await service.initialize(actionService: actionService);
      secondController.add('memex://quick_note');
      await pumpEventQueue();
      expect(
        actionService.consumeIfPending(),
        AppActionService.quickNoteAction,
      );

      await service.dispose();
      await firstController.close();
      await secondController.close();
    });
  });
}
