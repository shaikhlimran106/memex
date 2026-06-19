import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/repositories/card.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const userId = 'location_user';
  const cardId = '2026/06/18.md#ts_1';
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserStorage.saveUser(userId);
    await UserStorage.setLocale(const Locale('en'));
    tempDir = await Directory.systemTemp.createTemp('memex_card_location_');
    await FileSystemService.init(tempDir.path);

    await FileSystemService.instance.safeWriteCardFile(
      userId,
      cardId,
      const CardData(
        factId: cardId,
        timestamp: 1781790000,
        status: 'completed',
        tags: [],
        fact: 'Visited the square.',
        uiConfigs: [],
      ),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('updateCardLocation stores card override and reusable location mark',
      () async {
    final ok = await updateCardLocationEndpoint(
      cardId,
      31.2304,
      121.4737,
      'People Square',
    );

    expect(ok, isTrue);

    final card = await FileSystemService.instance.readCardFile(userId, cardId);
    expect(card, isNotNull);
    expect(card!.userFixedAddress, 'People Square');
    expect(card.userFixedLocation?.name, 'People Square');
    expect(card.userFixedLocation?.lat, closeTo(31.2304, 0.000001));
    expect(card.userFixedLocation?.lng, closeTo(121.4737, 0.000001));

    final markedLocation = await FileSystemService.instance
        .getUserLocationByName(userId, 'People Square');
    expect(markedLocation, isNotNull);
    expect(markedLocation!['name'], 'People Square');
    expect(markedLocation['lat'] as num, closeTo(31.2304, 0.000001));
    expect(markedLocation['lng'] as num, closeTo(121.4737, 0.000001));

    final nearest = await FileSystemService.instance.getNearestUserLocation(
      userId,
      31.23041,
      121.47371,
      10,
    );
    expect(nearest, 'People Square');
  });
}
