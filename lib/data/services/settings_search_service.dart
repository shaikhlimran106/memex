import 'package:memex/data/services/settings_registry.dart';
import 'package:memex/domain/models/settings_item.dart';

/// Settings search service. Pure local keyword search.
class SettingsSearchService {
  SettingsSearchService._();
  static final SettingsSearchService instance = SettingsSearchService._();

  /// Local keyword search. Matches against title, description, and keywords.
  /// Searches both Chinese and English content regardless of current locale.
  /// Empty query returns all items. Results sorted by relevanceScore descending.
  List<SettingsSearchResult> localSearch(String query) {
    if (query.trim().isEmpty) {
      return SettingsRegistry.allItems
          .map((item) => SettingsSearchResult(item: item))
          .toList();
    }

    final lowerQuery = query.toLowerCase();
    final results = <SettingsSearchResult>[];

    for (final item in SettingsRegistry.allItems) {
      final score = _calculateRelevance(item, lowerQuery);
      if (score > 0) {
        results.add(SettingsSearchResult(
          item: item,
          relevanceScore: score,
        ));
      }
    }

    results.sort((a, b) => b.relevanceScore.compareTo(a.relevanceScore));
    return results;
  }

  /// Calculate relevance score for a settings item against the query.
  /// Title match = 1.0, keyword match = 0.8, description match = 0.5.
  double _calculateRelevance(SettingsItem item, String lowerQuery) {
    // Title match has highest weight
    if (item.title.toLowerCase().contains(lowerQuery)) {
      return 1.0;
    }
    // Keyword match is next
    for (final keyword in item.keywords) {
      if (keyword.toLowerCase().contains(lowerQuery) ||
          lowerQuery.contains(keyword.toLowerCase())) {
        return 0.8;
      }
    }
    // Description match has lowest weight
    if (item.description.toLowerCase().contains(lowerQuery)) {
      return 0.5;
    }
    return 0.0;
  }
}
