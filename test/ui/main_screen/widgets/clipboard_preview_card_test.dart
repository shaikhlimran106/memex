import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/clipboard_preview_service.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/main_screen/widgets/clipboard_preview_card.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'user_id': 'preview-card-test'});
    await UserStorage.initL10n();
  });

  testWidgets('renders compact preview and exposes paste and dismiss actions', (
    tester,
  ) async {
    var pasteCount = 0;
    var dismissCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClipboardPreviewCard(
            candidate: const ClipboardPreviewCandidate(
              type: ClipboardPreviewCandidateType.text,
              text: 'first line\n\nsecond line',
              previewText: 'first line second line',
              hash: 'hash',
              characterCount: 24,
            ),
            onPaste: () => pasteCount += 1,
            onDismiss: () => dismissCount += 1,
          ),
        ),
      ),
    );

    expect(find.text(UserStorage.l10n.clipboardPreviewTitle), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.clipboardPreviewUnprocessed),
      findsOneWidget,
    );
    expect(find.text('first line second line'), findsOneWidget);

    await tester.tap(find.text(UserStorage.l10n.clipboardPreviewPasteToInput));
    await tester.pump();
    await tester.tap(find.byTooltip(UserStorage.l10n.ignore));
    await tester.pump();

    expect(pasteCount, 1);
    expect(dismissCount, 1);
  });

  testWidgets('renders image clipboard candidate with add image action', (
    tester,
  ) async {
    var pasteCount = 0;
    var dismissCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClipboardPreviewCard(
            candidate: const ClipboardPreviewCandidate(
              type: ClipboardPreviewCandidateType.image,
              hash: 'image-hash',
              previewText: '',
              imageUri: 'file:///tmp/clipboard.png',
              mimeType: 'image/png',
              fileName: 'clipboard.png',
            ),
            onPaste: () => pasteCount += 1,
            onDismiss: () => dismissCount += 1,
          ),
        ),
      ),
    );

    expect(
      find.text(UserStorage.l10n.clipboardPreviewImageTitle),
      findsOneWidget,
    );
    expect(
      find.text(UserStorage.l10n.clipboardPreviewImageDescription),
      findsOneWidget,
    );
    expect(
      find.text(UserStorage.l10n.clipboardPreviewAddImageToInput),
      findsOneWidget,
    );

    await tester.tap(
      find.text(UserStorage.l10n.clipboardPreviewAddImageToInput),
    );
    await tester.pump();
    await tester.tap(find.byTooltip(UserStorage.l10n.ignore));
    await tester.pump();

    expect(pasteCount, 1);
    expect(dismissCount, 1);
  });
}
