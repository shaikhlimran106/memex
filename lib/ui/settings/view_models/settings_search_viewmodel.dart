import 'package:flutter/material.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/data/services/settings_search_service.dart';
import 'package:memex/domain/models/settings_item.dart';

/// 设置搜索 ViewModel。管理搜索状态和结果。
class SettingsSearchViewModel extends ChangeNotifier {
  SettingsSearchViewModel({required MemexRouter router}) : _router = router;

  // ignore: unused_field — kept per project convention (ViewModels receive MemexRouter)
  final MemexRouter _router;
  final SettingsSearchService _searchService = SettingsSearchService.instance;

  String _query = '';
  List<SettingsSearchResult> _results = [];

  String get query => _query;
  List<SettingsSearchResult> get results => _results;
  bool get hasResults => _results.isNotEmpty;

  /// 更新搜索查询，立即执行本地搜索
  void updateQuery(String query) {
    _query = query;
    _results = _searchService.localSearch(query);
    notifyListeners();
  }

  /// 导航到设置项
  void navigateToItem(BuildContext context, SettingsItem item) {
    final page = item.navigationTarget.pageBuilder(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }
}
