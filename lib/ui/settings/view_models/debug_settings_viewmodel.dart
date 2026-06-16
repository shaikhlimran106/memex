import 'package:flutter/foundation.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/ui/settings/widgets/reprocess_cards_dialog.dart';
import 'package:memex/utils/user_storage.dart';

abstract interface class DebugSettingsDataController {
  Future<void> enqueueTask({
    required String taskType,
    required Map<String, dynamic> payload,
    String? bizId,
  });

  Future<void> clearData();

  Future<int> clearFailedAgentConversationContexts();

  Future<void> rebuildAllFtsIndexes();

  void resetForLogout();
}

class MemexRouterDebugSettingsDataController
    implements DebugSettingsDataController {
  MemexRouterDebugSettingsDataController(this._router);

  final MemexRouter _router;

  @override
  Future<void> enqueueTask({
    required String taskType,
    required Map<String, dynamic> payload,
    String? bizId,
  }) {
    return _router.enqueueTask(
      taskType: taskType,
      payload: payload,
      bizId: bizId,
    );
  }

  @override
  Future<void> clearData() => _router.clearData();

  @override
  Future<int> clearFailedAgentConversationContexts() {
    return _router.clearFailedAgentConversationContexts();
  }

  @override
  Future<void> rebuildAllFtsIndexes() => _router.rebuildAllFtsIndexes();

  @override
  void resetForLogout() => _router.resetForLogout();
}

class DebugSettingsUserNotFoundException implements Exception {
  const DebugSettingsUserNotFoundException();

  @override
  String toString() => 'User ID not found';
}

class DebugDateRangeTaskOptions {
  const DebugDateRangeTaskOptions({this.dateFrom, this.dateTo, this.limit});

  final DateTime? dateFrom;
  final DateTime? dateTo;
  final int? limit;

  Map<String, dynamic> toTaskPayload() {
    final payload = <String, dynamic>{};
    final from = dateFrom;
    if (from != null) {
      payload['date_from'] = formatDate(from);
    }
    final to = dateTo;
    if (to != null) {
      payload['date_to'] = formatDate(to);
    }
    final limitValue = limit;
    if (limitValue != null && limitValue > 0) {
      payload['limit'] = limitValue;
    }
    return payload;
  }

  static String formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

class DebugSettingsViewModel extends ChangeNotifier {
  DebugSettingsViewModel({required DebugSettingsDataController dataController})
      : _dataController = dataController;

  final DebugSettingsDataController _dataController;

  bool _isClearingData = false;
  bool _isClearingFailedAgentContexts = false;
  bool _isReprocessingCards = false;
  bool _isReprocessingComments = false;
  bool _isReprocessingKnowledgeBase = false;
  bool _isRebuildingSearchIndex = false;

  bool get isClearingData => _isClearingData;
  bool get isClearingFailedAgentContexts => _isClearingFailedAgentContexts;
  bool get isReprocessingCards => _isReprocessingCards;
  bool get isReprocessingComments => _isReprocessingComments;
  bool get isReprocessingKnowledgeBase => _isReprocessingKnowledgeBase;
  bool get isRebuildingSearchIndex => _isRebuildingSearchIndex;

  Future<void> clearToken() async {
    await UserStorage.clearUser();
    _dataController.resetForLogout();
  }

  Future<bool> clearData() async {
    if (_isClearingData) return false;

    await _runWithLoading(
      setLoading: (value) => _isClearingData = value,
      action: () async {
        await _ensureUser();
        await _dataController.clearData();
        await UserStorage.saveCachedAgentData('pkm', null);
        await UserStorage.saveCachedAgentData('card', null);
      },
    );
    return true;
  }

  Future<int?> clearFailedAgentContexts() async {
    if (_isClearingFailedAgentContexts) return null;

    return _runWithLoading(
      setLoading: (value) => _isClearingFailedAgentContexts = value,
      action: _dataController.clearFailedAgentConversationContexts,
    );
  }

  Future<bool> createReprocessCardsTask(
    ReprocessCardsDebugOptions options,
  ) async {
    if (_isReprocessingCards) return false;

    await _runWithLoading(
      setLoading: (value) => _isReprocessingCards = value,
      action: () async {
        await _ensureUser();
        await _dataController.enqueueTask(
          taskType: 'reprocess_cards_task',
          payload: options.toTaskPayload(),
          bizId: _createBizId('reprocess_cards'),
        );
      },
    );
    return true;
  }

  Future<bool> createReprocessCommentsTask(
    DebugDateRangeTaskOptions options,
  ) async {
    if (_isReprocessingComments) return false;

    await _runWithLoading(
      setLoading: (value) => _isReprocessingComments = value,
      action: () async {
        await _ensureUser();
        await _dataController.enqueueTask(
          taskType: 'reprocess_comments_task',
          payload: options.toTaskPayload(),
          bizId: _createBizId('reprocess_comments'),
        );
      },
    );
    return true;
  }

  Future<bool> createReprocessKnowledgeBaseTask(
    DebugDateRangeTaskOptions options,
  ) async {
    if (_isReprocessingKnowledgeBase) return false;

    await _runWithLoading(
      setLoading: (value) => _isReprocessingKnowledgeBase = value,
      action: () async {
        await _ensureUser();
        await _dataController.enqueueTask(
          taskType: 'reprocess_knowledge_base_task',
          payload: options.toTaskPayload(),
          bizId: _createBizId('reprocess_knowledge_base'),
        );
      },
    );
    return true;
  }

  Future<bool> rebuildSearchIndex() async {
    if (_isRebuildingSearchIndex) return false;

    await _runWithLoading(
      setLoading: (value) => _isRebuildingSearchIndex = value,
      action: _dataController.rebuildAllFtsIndexes,
    );
    return true;
  }

  Future<void> _ensureUser() async {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw const DebugSettingsUserNotFoundException();
    }
  }

  String _createBizId(String prefix) {
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<T> _runWithLoading<T>({
    required void Function(bool value) setLoading,
    required Future<T> Function() action,
  }) async {
    setLoading(true);
    notifyListeners();
    try {
      return await action();
    } finally {
      setLoading(false);
      notifyListeners();
    }
  }
}
