import 'package:flutter_test/flutter_test.dart';
import 'package:memex/domain/models/event_bus_message.dart';

void main() {
  test('parses profile update messages from event payloads', () {
    final parsed = EventBusMessage.fromJson({
      'type': 'profile_updated',
      'data': {
        'user_id': 'user-1',
        'avatar': 'workspace/_user/_System/media/avatar.heic',
      },
    });

    expect(parsed, isA<ProfileUpdatedMessage>());
    final message = parsed as ProfileUpdatedMessage;
    expect(message.type, EventBusMessageType.profileUpdated);
    expect(message.userId, 'user-1');
    expect(message.avatar, 'workspace/_user/_System/media/avatar.heic');
  });

  test('parses character update messages from event payloads', () {
    final parsed = EventBusMessage.fromJson({
      'type': 'character_updated',
      'data': {
        'user_id': 'user-1',
        'character_id': 'mentor',
      },
    });

    expect(parsed, isA<CharacterUpdatedMessage>());
    final message = parsed as CharacterUpdatedMessage;
    expect(message.type, EventBusMessageType.characterUpdated);
    expect(message.userId, 'user-1');
    expect(message.characterId, 'mentor');
  });
}
