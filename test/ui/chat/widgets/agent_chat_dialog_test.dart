import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/chat/widgets/agent_chat_dialog.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
  });

  group('AgentChatDialog layout metrics', () {
    test('resolves default sheet and full-screen heights', () {
      const viewport = Size(390, 800);

      expect(resolveAgentChatDialogHeight(viewport, isFullScreen: false), 600);
      expect(resolveAgentChatDialogHeight(viewport, isFullScreen: true), 800);
      expect(
        resolveAgentChatDialogHeight(
          viewport,
          isFullScreen: false,
          keyboardInset: 320,
        ),
        480,
      );
      expect(
        resolveAgentChatDialogHeight(
          viewport,
          isFullScreen: true,
          keyboardInset: 320,
        ),
        480,
      );
    });

    test('uses rounded sheet corners only outside full screen', () {
      expect(
        resolveAgentChatDialogBorderRadius(isFullScreen: false),
        const BorderRadius.vertical(top: Radius.circular(32)),
      );
      expect(
        resolveAgentChatDialogBorderRadius(isFullScreen: true),
        BorderRadius.zero,
      );
    });

    test('uses keyboard inset whenever the keyboard is visible and editable',
        () {
      expect(
        resolveSuperAgentInputBottomInset(
          keyboardInset: 320,
          inputFocused: true,
          isStreaming: false,
        ),
        320,
      );
      expect(
        resolveSuperAgentInputBottomInset(
          keyboardInset: 320,
          inputFocused: true,
          isStreaming: true,
        ),
        0,
      );
      expect(
        resolveSuperAgentInputBottomInset(
          keyboardInset: 320,
          inputFocused: false,
          isStreaming: false,
        ),
        320,
      );
    });

    test('hides photo suggestions while the super agent is sending', () {
      expect(
        shouldShowSuperAgentPhotoSuggestions(
          isStreaming: false,
          isLoading: true,
          hasSuggestions: false,
        ),
        isTrue,
      );
      expect(
        shouldShowSuperAgentPhotoSuggestions(
          isStreaming: false,
          isLoading: false,
          hasSuggestions: true,
        ),
        isTrue,
      );
      expect(
        shouldShowSuperAgentPhotoSuggestions(
          isStreaming: true,
          isLoading: true,
          hasSuggestions: true,
        ),
        isFalse,
      );
    });

    test('disables the composer while the super agent is running', () {
      expect(canEditSuperAgentComposer(isStreaming: false), isTrue);
      expect(canEditSuperAgentComposer(isStreaming: true), isFalse);
    });

    test('keeps original filenames only for selected initial images', () {
      final selected = [
        XFile('/tmp/a.jpg'),
        XFile('/tmp/b.jpg'),
      ];

      expect(
        initialOriginalFilenamesForSelectedImages(selected, {
          '/tmp/a.jpg': 'camera-original.jpg',
          '/tmp/b.jpg': ' ',
          '/tmp/unused.jpg': 'unused.jpg',
        }),
        {'/tmp/a.jpg': 'camera-original.jpg'},
      );
    });
  });

  group('AgentChatDialog full-screen affordance', () {
    testWidgets('starts as a bottom sheet with a full-screen action', (
      tester,
    ) async {
      await _pumpDialog(tester);

      expect(find.text(UserStorage.l10n.aiInputHint), findsWidgets);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip(UserStorage.l10n.chatHistory), findsNothing);
      expect(
        find.byTooltip(UserStorage.l10n.enterFullScreenTooltip),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      expect(find.byTooltip(UserStorage.l10n.close), findsOneWidget);

      final container = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('agent_chat_dialog_container')),
      );
      final decoration = container.decoration! as BoxDecoration;

      expect(
        tester
            .getSize(find.byKey(const ValueKey('agent_chat_dialog_container')))
            .height,
        600,
      );
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(32)),
      );
    });

    testWidgets('expands to full screen and restores the sheet', (
      tester,
    ) async {
      await _pumpDialog(tester);

      await tester.tap(
        find.byKey(const ValueKey('agent_chat_fullscreen_toggle')),
      );
      await tester.pumpAndSettle();

      var container = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('agent_chat_dialog_container')),
      );
      var decoration = container.decoration! as BoxDecoration;

      expect(
        tester
            .getSize(find.byKey(const ValueKey('agent_chat_dialog_container')))
            .height,
        800,
      );
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(
        find.byTooltip(UserStorage.l10n.exitFullScreenTooltip),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('agent_chat_fullscreen_toggle')),
      );
      await tester.pumpAndSettle();

      container = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('agent_chat_dialog_container')),
      );
      decoration = container.decoration! as BoxDecoration;

      expect(
        tester
            .getSize(find.byKey(const ValueKey('agent_chat_dialog_container')))
            .height,
        600,
      );
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(32)),
      );
      expect(
        find.byTooltip(UserStorage.l10n.enterFullScreenTooltip),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
    });

    testWidgets(
      'keeps header actions inside the compact header on narrow screens',
      (tester) async {
        await _pumpDialog(
          tester,
          viewportSize: const Size(320, 800),
        );

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('agent_chat_fullscreen_toggle')),
          findsOneWidget,
        );
        expect(find.byTooltip(UserStorage.l10n.close), findsOneWidget);
      },
    );

    testWidgets('super agent entry hides chat controls and uses send input', (
      tester,
    ) async {
      await _pumpDialog(tester);

      expect(find.byTooltip(UserStorage.l10n.chatHistory), findsNothing);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(
        find.byKey(const ValueKey('super_agent_camera_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('super_agent_gallery_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('super_agent_publish_button')),
        findsOneWidget,
      );
      expect(find.text(UserStorage.l10n.sendLabel), findsOneWidget);
    });

    testWidgets('running super agent keeps the composer unfocusable', (
      tester,
    ) async {
      await _pumpDialog(tester, initialIsStreamingForTesting: true);

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.readOnly, isTrue);
      expect(textField.canRequestFocus, isFalse);
      expect(textField.enableInteractiveSelection, isFalse);

      await tester.tap(find.byType(TextField), warnIfMissed: false);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);

      final publishButton = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('super_agent_publish_button')),
      );
      expect(publishButton.onTap, isNull);

      final runModeChip = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('super_agent_run_mode_chip')),
      );
      expect(runModeChip.onTap, isNull);
    });

    testWidgets('keeps super agent header actions tight to the right edge', (
      tester,
    ) async {
      const viewportSize = Size(390, 800);
      await _pumpDialog(
        tester,
        viewportSize: viewportSize,
      );

      final dialogRect = tester.getRect(
        find.byKey(const ValueKey('agent_chat_dialog_container')),
      );
      final fullscreenButtonRect = tester.getRect(
        find.byKey(const ValueKey('agent_chat_fullscreen_toggle')),
      );
      final closeButtonFinder =
          find.byKey(const ValueKey('agent_chat_close_button'));
      final closeButtonRect = tester.getRect(closeButtonFinder);
      final closeIconRect = tester.getRect(
        find.descendant(
          of: closeButtonFinder,
          matching: find.byIcon(Icons.close),
        ),
      );

      expect(dialogRect.width, moreOrLessEquals(viewportSize.width));
      expect(closeButtonRect.size, const Size.square(36));
      expect(fullscreenButtonRect.size, const Size.square(36));
      expect(
        dialogRect.right - closeButtonRect.right,
        moreOrLessEquals(4),
      );
      expect(
        viewportSize.width - closeButtonRect.right,
        moreOrLessEquals(4),
      );
      expect(closeIconRect.right, greaterThan(dialogRect.right - 13));
      expect(closeIconRect.right, greaterThan(viewportSize.width - 13));
      expect(closeButtonRect.left - fullscreenButtonRect.right, 0);
    });
  });
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  Size viewportSize = const Size(390, 800),
  bool initialIsStreamingForTesting = false,
}) async {
  tester.view.physicalSize = viewportSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentChatDialog(
          initialIsStreamingForTesting: initialIsStreamingForTesting,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
