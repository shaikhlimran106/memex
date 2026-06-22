import 'package:memex/domain/models/card_detail_model.dart';

String formatAssetReferenceForAgent(AssetData asset) {
  final url = asset.url.trim();
  if (url.startsWith('fs://')) return url;

  final uri = Uri.tryParse(url);
  if (uri == null) return url;

  final segments = uri.pathSegments;
  final assetsIndex = segments.indexOf('assets');
  if (assetsIndex < 0 || segments.length <= assetsIndex + 2) {
    return url;
  }

  final filename = segments[assetsIndex + 2].trim();
  if (filename.isEmpty) return url;
  return 'fs://$filename';
}
