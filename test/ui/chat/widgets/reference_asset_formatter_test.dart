import 'package:flutter_test/flutter_test.dart';
import 'package:memex/domain/models/card_detail_model.dart';
import 'package:memex/ui/chat/widgets/reference_asset_formatter.dart';

void main() {
  test('formats local asset preview urls as fs refs for agent context', () {
    final asset = AssetData(
      type: 'image',
      url: 'http://127.0.0.1:12345/assets/user%20id/photo_1.jpg?token=local',
    );

    expect(formatAssetReferenceForAgent(asset), 'fs://photo_1.jpg');
  });

  test('keeps existing fs and remote urls unchanged', () {
    expect(
      formatAssetReferenceForAgent(
        AssetData(type: 'image', url: 'fs://photo.jpg'),
      ),
      'fs://photo.jpg',
    );
    expect(
      formatAssetReferenceForAgent(
        AssetData(type: 'image', url: 'https://example.com/photo.jpg'),
      ),
      'https://example.com/photo.jpg',
    );
  });
}
