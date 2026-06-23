import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/core/widgets/language_picker.dart';

void main() {
  testWidgets('compact language value stays inline without code or subtitle',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: Text('Choose Language')),
              LanguageValueButton(
                localeTag: 'ru',
                compact: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Русский'), findsOneWidget);
    expect(find.text('Russian'), findsNothing);
    expect(find.text('RU'), findsNothing);
    expect(find.byIcon(Icons.translate_outlined), findsNothing);
  });

  testWidgets('shows scalable language list and returns selected tag',
      (tester) async {
    String? selectedTag;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    selectedTag = await showLanguagePickerSheet(
                      context: context,
                      selectedLocaleTag: 'en',
                      title: 'Choose Language',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text('EN'), findsNothing);
    expect(find.text('RU'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Bahasa Indonesia'),
      200,
      scrollable: find.byType(Scrollable).last,
    );

    expect(find.text('Bahasa Indonesia'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Русский'),
      200,
      scrollable: find.byType(Scrollable).last,
    );

    expect(find.text('Русский'), findsOneWidget);

    await tester.tap(find.text('Русский'));
    await tester.pumpAndSettle();

    expect(selectedTag, 'ru');
  });
}
