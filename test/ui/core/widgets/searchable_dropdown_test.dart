import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/core/widgets/searchable_dropdown.dart';

void main() {
  testWidgets('dropdown arrow clears focus from another active text field', (
    tester,
  ) async {
    final otherFocusNode = FocusNode();
    addTearDown(otherFocusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(
                key: const ValueKey('base_url_field'),
                focusNode: otherFocusNode,
              ),
              SearchableDropdown(
                options: const ['kimi-k2.5', 'kimi-k2.6'],
                initialValue: 'kimi-k2.6',
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('base_url_field')));
    await tester.pump();
    expect(otherFocusNode.hasFocus, isTrue);

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pump();

    expect(otherFocusNode.hasFocus, isFalse);
    await tester.pump();
    expect(find.text('kimi-k2.5'), findsOneWidget);
  });
}
