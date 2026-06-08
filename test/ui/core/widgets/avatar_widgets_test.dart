import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/core/widgets/character_avatar.dart';
import 'package:memex/ui/core/widgets/dicebear_avatar.dart';
import 'package:memex/ui/core/widgets/local_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CharacterAvatar routes HEIC media paths through LocalImage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CharacterAvatar(
          avatar: 'workspace/_user/_System/media/avatar.heic',
          name: 'User',
        ),
      ),
    );

    expect(find.byType(LocalImage), findsOneWidget);
    expect(find.byType(DiceBearAvatar), findsNothing);
  });

  testWidgets('DiceBearAvatar shows a stable placeholder for empty seeds', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DiceBearAvatar(seed: null, size: 48)),
    );

    expect(find.byIcon(Icons.person), findsOneWidget);
  });
}
