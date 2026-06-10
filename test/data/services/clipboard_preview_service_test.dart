import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/clipboard_preview_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String? clipboardText;
  final service = ClipboardPreviewService.instance;

  setUp(() {
    clipboardText = 'Remember to discuss the clipboard preview.';
    SharedPreferences.setMockInitialValues({'user_id': 'test_user'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('ClipboardPreviewService', () {
    test(
      'returns text clipboard candidate when it has not been handled',
      () async {
        final candidate = await service.fetchUnhandledText();

        expect(candidate, isNotNull);
        expect(candidate!.text, clipboardText);
        expect(candidate.hash, isNotEmpty);
      },
    );

    test('trims clipboard text and collapses preview whitespace', () async {
      clipboardText = '  line one\n\nline two\t line three  ';

      final candidate = await service.fetchUnhandledText();

      expect(candidate, isNotNull);
      expect(candidate!.text, 'line one\n\nline two\t line three');
      expect(candidate.previewText, 'line one line two line three');
      expect(candidate.characterCount, candidate.text.runes.length);
    });

    test('ignores blank clipboard text', () async {
      clipboardText = ' \n\t ';

      expect(await service.fetchUnhandledText(), isNull);
    });

    test(
      'does not return the same candidate after it is marked handled',
      () async {
        final candidate = await service.fetchUnhandledText();
        expect(candidate, isNotNull);

        await service.markHandled(candidate!);

        expect(await service.fetchUnhandledText(), isNull);
      },
    );

    test('handled clipboard hashes are scoped per user', () async {
      final candidate = await service.fetchUnhandledText();
      expect(candidate, isNotNull);

      await service.markHandled(candidate!);
      expect(await service.fetchUnhandledText(), isNull);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', 'another_user');
      expect(await service.fetchUnhandledText(), isNotNull);

      await prefs.setString('user_id', 'test_user');
      expect(await service.fetchUnhandledText(), isNull);
    });

    test('keeps only the most recent handled hashes', () async {
      for (var i = 0; i < 81; i += 1) {
        await service.markTextHandled('handled text $i');
      }

      clipboardText = 'handled text 80';
      expect(await service.fetchUnhandledText(), isNull);

      clipboardText = 'handled text 0';
      final droppedCandidate = await service.fetchUnhandledText();
      expect(droppedCandidate, isNotNull);
      expect(droppedCandidate!.text, 'handled text 0');
    });

    test(
      'marks clipboard handled when current input already contains it',
      () async {
        final first = await service.fetchUnhandledText(
          currentText: 'Draft\n$clipboardText',
        );

        expect(first, isNull);
        expect(await service.fetchUnhandledText(), isNull);
      },
    );
  });
}
