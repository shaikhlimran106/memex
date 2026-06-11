import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/clipboard_preview_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String? clipboardText;
  late Directory tempDir;
  final service = ClipboardPreviewService.instance;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('clipboard_preview_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') return tempDir.path;
        return null;
      },
    );
  });

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.memexlab.memex/clipboard_preview'),
      (_) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.memexlab.memex/clipboard_preview'),
      null,
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ClipboardPreviewService', () {
    test(
      'returns text clipboard candidate when it has not been handled',
      () async {
        final candidate = await service.fetchUnhandledText();

        expect(candidate, isNotNull);
        expect(candidate!.text, clipboardText);
        expect(candidate.isText, isTrue);
        expect(candidate.hash, isNotEmpty);
      },
    );

    test('trims clipboard text and collapses preview whitespace', () async {
      clipboardText = '  line one\n\nline two\t line three  ';

      final candidate = await service.fetchUnhandledText();

      expect(candidate, isNotNull);
      expect(candidate!.text, 'line one\n\nline two\t line three');
      expect(candidate.previewText, 'line one line two line three');
      expect(candidate.characterCount, candidate.text!.runes.length);
    });

    test('keeps full plain text while bounding the preview text', () async {
      clipboardText = List.filled(1000, 'plain text').join(' ');

      final candidate = await service.fetchUnhandledText();

      expect(candidate, isNotNull);
      expect(candidate!.isText, isTrue);
      expect(candidate.text, clipboardText);
      expect(candidate.characterCount, clipboardText!.runes.length);
      expect(candidate.previewText.length, lessThanOrEqualTo(243));
      expect(candidate.previewText.endsWith('...'), isTrue);
    });

    test('treats image data URI as an image candidate', () async {
      clipboardText =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ';

      final candidate = await service.fetchUnhandledText();

      expect(candidate, isNotNull);
      expect(candidate!.isImage, isTrue);
      expect(candidate.text, isNull);
      expect(candidate.mimeType, 'image/png');
      expect(candidate.previewText, isEmpty);
      expect(candidate.dataUri, clipboardText);
    });

    test('materializes image data URI into a temporary image file', () async {
      clipboardText = 'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
          'AAAADUlEQVR42mP8z8BQDwAFgwJ/l6WPOwAAAABJRU5ErkJggg==';
      final candidate = await service.fetchUnhandledText();
      expect(candidate, isNotNull);
      expect(candidate!.isImage, isTrue);

      final image = await service.materializeImage(candidate);

      expect(image, isNotNull);
      expect(await image!.length(), greaterThan(0));
      expect(image.path.endsWith('.png'), isTrue);
    });

    test('treats image file URI as an image candidate', () async {
      clipboardText = 'file:///tmp/memex_clipboard_image.jpg';

      final candidate = await service.fetchUnhandledText();

      expect(candidate, isNotNull);
      expect(candidate!.isImage, isTrue);
      expect(candidate.imageUri, clipboardText);
      expect(candidate.mimeType, 'image/jpeg');
      expect(candidate.fileName, 'memex_clipboard_image.jpg');
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
