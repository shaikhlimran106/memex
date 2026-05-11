import 'package:flutter/widgets.dart';

/// Navigation target describing how to navigate to the page containing a setting.
class NavigationTarget {
  const NavigationTarget({
    required this.pageBuilder,
  });

  /// Page builder function. Returns the target Widget.
  /// Uses a function instead of a route string because existing settings pages
  /// are not in the go_router route table.
  final Widget Function(BuildContext context) pageBuilder;
}

/// Data model for a searchable settings item.
class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.titleGetter,
    required this.descriptionGetter,
    required this.keywords,
    required this.icon,
    required this.navigationTarget,
    required this.parentPathGetter,
  });

  /// Unique identifier, e.g. 'settings.language'
  final String id;

  /// Returns the localized title using the current l10n.
  final String Function() titleGetter;

  /// Returns the localized description using the current l10n.
  final String Function() descriptionGetter;

  /// Searchable keywords (both Chinese and English, always searched regardless of locale).
  final List<String> keywords;

  /// Display icon.
  final IconData icon;

  /// Navigation target.
  final NavigationTarget navigationTarget;

  /// Returns the localized breadcrumb path segments using the current l10n.
  /// e.g. ['Personal Center', 'Settings']
  final List<String> Function() parentPathGetter;

  /// Get the current localized title.
  String get title => titleGetter();

  /// Get the current localized description.
  String get description => descriptionGetter();

  /// Get the breadcrumb string for display.
  String get breadcrumb {
    final path = parentPathGetter();
    if (path.isEmpty) return title;
    return '${path.join(' > ')} > $title';
  }
}

/// Search result wrapping a SettingsItem with relevance metadata.
class SettingsSearchResult {
  const SettingsSearchResult({
    required this.item,
    this.relevanceScore = 0.0,
  });

  final SettingsItem item;

  /// Relevance score (0.0-1.0) for sorting.
  final double relevanceScore;
}
