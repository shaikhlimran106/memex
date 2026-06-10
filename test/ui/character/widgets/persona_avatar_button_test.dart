import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/character/widgets/persona_avatar_button.dart';
import 'package:memex/ui/core/widgets/character_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders an empty slot before a user is available', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: PersonaAvatarButton())),
    );
    await tester.pump();

    expect(find.byType(CharacterAvatar), findsNothing);
  });
}
