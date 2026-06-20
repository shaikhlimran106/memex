import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/data/services/event_handlers/timeline_card_change_handler.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/domain/models/system_event.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('memex_timeline_events_');
    await FileSystemService.init(tempRoot.path);
  });

  tearDown(() async {
    EventBusService.instance.clearHandlers();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('emits card added when a processing placeholder completes', () async {
    const factId = '2026/06/20.md#ts_1';
    final before = _card(factId, status: 'processing');
    final after = _card(
      factId,
      status: 'completed',
      title: 'Finished card',
      fact: 'The agent finished the record.',
    );

    final messages = await _collectTimelineEvents(() {
      return handleTimelineCardChanged(
        'user_1',
        SystemEvent<DataChangeRecord>(
          type: SystemEventTypes.dataChanged,
          source: 'test',
          payload: DataChangeRecord(
            op: DataChangeOp.update,
            ns: DataChangeNs.card,
            documentKey: factId,
            before: before.toJson(),
            after: after.toJson(),
          ),
        ),
      );
    });

    expect(messages, hasLength(1));
    expect(messages.single, isA<CardAddedMessage>());
    final message = messages.single as CardAddedMessage;
    expect(message.id, factId);
    expect(message.status, 'completed');
    expect(message.title, 'Finished card');
    expect(message.rawText, 'The agent finished the record.');
  });

  test('emits card updated when an existing completed card changes', () async {
    const factId = '2026/06/20.md#ts_2';
    final before = _card(
      factId,
      status: 'completed',
      title: 'Before',
      fact: 'Before text.',
    );
    final after = _card(
      factId,
      status: 'completed',
      title: 'After',
      fact: 'After text.',
    );

    final messages = await _collectTimelineEvents(() {
      return handleTimelineCardChanged(
        'user_1',
        SystemEvent<DataChangeRecord>(
          type: SystemEventTypes.dataChanged,
          source: 'test',
          payload: DataChangeRecord(
            op: DataChangeOp.update,
            ns: DataChangeNs.card,
            documentKey: factId,
            before: before.toJson(),
            after: after.toJson(),
          ),
        ),
      );
    });

    expect(messages, hasLength(1));
    expect(messages.single, isA<CardUpdatedMessage>());
    final message = messages.single as CardUpdatedMessage;
    expect(message.id, factId);
    expect(message.title, 'After');
    expect(message.rawText, 'After text.');
  });
}

CardData _card(
  String factId, {
  required String status,
  String? title,
  String? fact,
}) {
  return CardData(
    factId: factId,
    timestamp: 1781971200,
    status: status,
    tags: const ['Knowledge'],
    title: title,
    fact: fact,
    uiConfigs: [
      UiConfig(
        templateId: 'article',
        data: {'body': fact ?? 'Body'},
      ),
    ],
  );
}

Future<List<EventBusMessage>> _collectTimelineEvents(
  Future<void> Function() action,
) async {
  final messages = <EventBusMessage>[];
  final eventBus = EventBusService.instance;
  eventBus.clearHandlers();
  await eventBus.connect();

  void collect(EventBusMessage message) {
    messages.add(message);
  }

  eventBus.addHandler(EventBusMessageType.cardAdded, collect);
  eventBus.addHandler(EventBusMessageType.cardUpdated, collect);

  await action();
  await Future<void>.delayed(Duration.zero);

  eventBus.removeHandler(EventBusMessageType.cardAdded, collect);
  eventBus.removeHandler(EventBusMessageType.cardUpdated, collect);
  return messages;
}
