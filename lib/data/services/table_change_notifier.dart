import 'dart:async';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/logger.dart';

/// Callback signature for table change handlers.
typedef TableChangeHandler = void Function(Set<TableUpdate> updates);

/// Listens to Drift's table-level invalidation stream and dispatches
/// callbacks when watched tables change.
///
/// This is pure infrastructure — it knows nothing about business logic.
/// Services register their own handlers via [watch] to react to table changes.
///
/// Usage:
/// ```dart
/// // In MemexRouter._init(), after AppDatabase.init():
/// TableChangeNotifier.instance.init();
///
/// // In any service that cares about table changes:
/// TableChangeNotifier.instance.watch('my_table', (updates) {
///   // handle change
/// });
/// ```
class TableChangeNotifier {
  TableChangeNotifier._();
  static final instance = TableChangeNotifier._();

  final Logger _logger = getLogger('TableChangeNotifier');
  StreamSubscription<Set<TableUpdate>>? _subscription;
  final Map<String, List<TableChangeHandler>> _handlers = {};

  /// Start listening to table changes. Call once after [AppDatabase.init].
  void init() {
    _subscription?.cancel();

    _subscription = AppDatabase.instance.tableUpdates().listen(
      (updates) {
        for (final update in updates) {
          final handlers = _handlers[update.table];
          if (handlers == null) continue;
          for (final handler in handlers) {
            try {
              handler(updates);
            } catch (e) {
              _logger.severe(
                  'Error in table change handler for ${update.table}: $e');
            }
          }
        }
      },
      onError: (e) {
        _logger.severe('Table update stream error: $e');
      },
    );

    _logger.info('TableChangeNotifier initialized');
  }

  /// Register a handler for changes on a specific table.
  void watch(String tableName, TableChangeHandler handler) {
    _handlers.putIfAbsent(tableName, () => []).add(handler);
  }

  /// Stop listening and clear all handlers.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _handlers.clear();
  }
}
