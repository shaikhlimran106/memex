import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:memex/data/services/clipboard_preview_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/input_draft_service.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/main_screen/widgets/clipboard_preview_card.dart';
import 'package:memex/ui/main_screen/widgets/input_sheet.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDataRoot;
  String? clipboardText;

  setUpAll(() async {
    const recordChannel = MethodChannel('com.llfbandit.record/messages');
    const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
    const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(recordChannel, (call) async {
      switch (call.method) {
        case 'hasPermission':
        case 'isPaused':
        case 'isRecording':
        case 'isEncoderSupported':
          return false;
        case 'listInputDevices':
          return <Object>[];
        case 'getAmplitude':
          return {'current': 0.0, 'max': 0.0};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(audioGlobalChannel, (_) async => null);
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    messenger.setMockMethodCallHandler(audioPlayerChannel, (call) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map<Object?, Object?>?;
        final playerId = arguments?['playerId'] as String?;
        if (playerId != null) {
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$playerId'),
            MockStreamHandler.inline(onListen: (arguments, events) {}),
          );
        }
      }
      return null;
    });

    SharedPreferences.setMockInitialValues({'user_id': 'input-sheet-test'});
    await UserStorage.initL10n();

    testDataRoot = await Directory.systemTemp.createTemp('memex_input_sheet_');
    await FileSystemService.init(testDataRoot.path);
  });

  setUp(() async {
    clipboardText = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', 'input-sheet-test');
    await prefs.remove(
      'clipboard_preview_handled_hashes_input-sheet-test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': clipboardText};
      }
      return null;
    });
    await InputDraftService.instance.clearActiveDraft();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  tearDownAll(() async {
    await LocalAssetServer.stopServer();
    if (await testDataRoot.exists()) {
      await testDataRoot.delete(recursive: true);
    }
  });

  Widget buildHost({
    InputData? initialData,
    Future<bool> Function(InputData data)? onSubmit,
  }) {
    var isOpen = true;
    var closeCount = 0;

    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            return Stack(
              children: [
                const Center(child: Text('Home content')),
                InputSheet(
                  isOpen: isOpen,
                  initialData: initialData ?? InputData(text: 'started note'),
                  onClose: () {
                    setState(() {
                      isOpen = false;
                      closeCount += 1;
                    });
                  },
                  onSubmit: onSubmit ?? (_) async => true,
                ),
                Text('close count: $closeCount'),
              ],
            );
          },
        ),
      ),
    );
  }

  testWidgets('Android back closes the open input sheet without popping home', (
    tester,
  ) async {
    await tester.pumpWidget(buildHost());
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Home content'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'typed before back');
    await tester.pump();

    final handled = await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 50));

    expect(handled, isTrue);
    expect(find.text('Home content'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('close count: 1'), findsOneWidget);
  });

  testWidgets('clipboard preview pastes into the input without submitting', (
    tester,
  ) async {
    clipboardText = 'clipboard note';
    var submitCount = 0;

    final directCandidate =
        await ClipboardPreviewService.instance.fetchUnhandledText();
    expect(directCandidate?.text, 'clipboard note');

    await tester.pumpWidget(
      buildHost(
        initialData: InputData(text: ''),
        onSubmit: (_) async {
          submitCount += 1;
          return true;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(TextField));
    await pumpUntilFound(tester, find.byType(ClipboardPreviewCard));

    expect(find.byType(ClipboardPreviewCard), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.clipboardPreviewPasteToInput),
      findsOneWidget,
    );

    await tester.tap(find.text(UserStorage.l10n.clipboardPreviewPasteToInput));
    await tester.pump();
    await pumpUntilGone(tester, find.byType(ClipboardPreviewCard));

    expect(find.byType(ClipboardPreviewCard), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'clipboard note',
    );
    expect(submitCount, 0);
  });

  testWidgets(
    'clipboard preview is suppressed when the input already contains the clipboard',
    (tester) async {
      clipboardText = 'already included';

      await tester.pumpWidget(
        buildHost(
          initialData: InputData(text: 'draft with already included text'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(ClipboardPreviewCard), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(ClipboardPreviewCard), findsNothing);
    },
  );

  testWidgets('dismissing clipboard preview hides it for the same clipboard', (
    tester,
  ) async {
    clipboardText = 'dismiss me';

    await tester.pumpWidget(buildHost(initialData: InputData(text: '')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(TextField));
    await pumpUntilFound(tester, find.byType(ClipboardPreviewCard));

    expect(find.byType(ClipboardPreviewCard), findsOneWidget);

    await tester.tap(find.byTooltip(UserStorage.l10n.ignore));
    await tester.pump();
    await pumpUntilGone(tester, find.byType(ClipboardPreviewCard));

    expect(find.byType(ClipboardPreviewCard), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ClipboardPreviewCard), findsNothing);
  });

  testWidgets(
    'unsafe selected image uses safety placeholder in preview strip',
    (tester) async {
      final image = File('${testDataRoot.path}/unsafe_selected.png');
      image.writeAsBytesSync(_pngHeader(width: 1000, height: 13000));

      await tester.pumpWidget(
        buildHost(
          initialData: InputData(
            text: 'long screenshot',
            images: [XFile(image.path)],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('successful submit clears draft and suppresses dispose saves', (
    tester,
  ) async {
    final submitCompleter = Completer<bool>();
    InputData? submittedData;

    await tester.pumpWidget(
      buildSubmitHost(
        onSubmit: (data, closeSheet) {
          submittedData = data;
          closeSheet();
          return submitCompleter.future;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    await tester.enterText(find.byType(TextField), 'sent note');
    await tester.pump();
    await saveActiveDraft(tester, 'sent note');
    expect(await activeDraftText(tester), 'sent note');

    final submitButton = find.byKey(
      const ValueKey('input_sheet_submit_button'),
    );
    await tester.runAsync<void>(() async {
      tester.widget<GestureDetector>(submitButton).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(submittedData?.text, 'sent note');
    expect(await activeDraftText(tester), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    expect(await activeDraftText(tester), isNull);

    await tester.runAsync<void>(() async {
      submitCompleter.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(await activeDraftText(tester), isNull);
  });

  testWidgets('failed submit writes the submitted text back to draft', (
    tester,
  ) async {
    final submitCompleter = Completer<bool>();

    await tester.pumpWidget(
      buildSubmitHost(
        onSubmit: (data, closeSheet) {
          closeSheet();
          return submitCompleter.future;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    await tester.enterText(find.byType(TextField), 'keep on failure');
    await tester.pump();
    await saveActiveDraft(tester, 'keep on failure');

    final submitButton = find.byKey(
      const ValueKey('input_sheet_submit_button'),
    );
    await tester.runAsync<void>(() async {
      tester.widget<GestureDetector>(submitButton).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(await activeDraftText(tester), isNull);

    await tester.runAsync<void>(() async {
      submitCompleter.complete(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(await activeDraftText(tester), 'keep on failure');
  });
}

typedef SubmitHostCallback = Future<bool> Function(
    InputData data, VoidCallback closeSheet);

Widget buildSubmitHost({required SubmitHostCallback onSubmit}) {
  var isOpen = true;

  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) {
          return Stack(
            children: [
              InputSheet(
                isOpen: isOpen,
                onClose: () {
                  setState(() => isOpen = false);
                },
                onSubmit: (data) {
                  return onSubmit(data, () {
                    setState(() => isOpen = false);
                  });
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

Future<String?> activeDraftText(WidgetTester tester) {
  return tester.runAsync<String?>(() async {
    final draft = await InputDraftService.instance.loadActiveDraft();
    return draft?.text;
  });
}

Future<void> saveActiveDraft(WidgetTester tester, String text) {
  return tester.runAsync<void>(() {
    return InputDraftService.instance.saveTextDraft(text);
  });
}

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
}

List<int> _pngHeader({required int width, required int height}) {
  final bytes = Uint8List(33);
  bytes.setAll(0, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    0x00,
    0x00,
    0x00,
    0x0d,
    0x49,
    0x48,
    0x44,
    0x52,
  ]);
  _writeUint32Be(bytes, 16, width);
  _writeUint32Be(bytes, 20, height);
  bytes.setAll(24, const [
    0x08,
    0x02,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  return bytes;
}

void _writeUint32Be(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xff;
  bytes[offset + 1] = (value >> 16) & 0xff;
  bytes[offset + 2] = (value >> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
}
