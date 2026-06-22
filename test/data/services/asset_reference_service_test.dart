import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/asset_reference_service.dart';

void main() {
  group('AssetReferenceService.extractReferences', () {
    test('extracts bare fs refs wrapped in markdown-style prose', () {
      const text = '附件 `fs://img_20260618_ts_0_no_1_1080x2400.jpg`）。'
          '另一个 ![image](fs://photo.jpg)。';

      expect(
        AssetReferenceService.extractReferences(text),
        [
          'fs://img_20260618_ts_0_no_1_1080x2400.jpg',
          'fs://photo.jpg',
        ],
      );
    });

    test('cleans file names from inline-code refs', () {
      expect(
        AssetReferenceService.extractFileNameFromReference(
          '`fs://img_20260618_ts_0_no_1_1080x2400.jpg`）。',
        ),
        'img_20260618_ts_0_no_1_1080x2400.jpg',
      );
    });
  });
}
