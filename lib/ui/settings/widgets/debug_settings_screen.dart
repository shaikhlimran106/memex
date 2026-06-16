import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/routing/routes.dart';
import 'package:memex/ui/settings/view_models/debug_settings_viewmodel.dart';
import 'package:memex/ui/settings/widgets/debug_settings_page.dart';
import 'package:memex/ui/settings/widgets/reprocess_cards_dialog.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:provider/provider.dart';

class DebugSettingsActionScope extends InheritedWidget {
  const DebugSettingsActionScope({
    super.key,
    required this.dataController,
    required super.child,
  });

  final DebugSettingsDataController dataController;

  static DebugSettingsDataController? maybeControllerOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<DebugSettingsActionScope>();
    final scope = element?.widget as DebugSettingsActionScope?;
    return scope?.dataController;
  }

  @override
  bool updateShouldNotify(DebugSettingsActionScope oldWidget) {
    return dataController != oldWidget.dataController;
  }
}

class DebugSettingsScreen extends StatefulWidget {
  const DebugSettingsScreen({
    super.key,
    required this.dataController,
    this.scaffoldMessengerKey,
  });

  factory DebugSettingsScreen.forRouter({
    Key? key,
    required MemexRouter router,
  }) {
    return DebugSettingsScreen(
      key: key,
      dataController: MemexRouterDebugSettingsDataController(router),
    );
  }

  factory DebugSettingsScreen.fromContext(BuildContext context, {Key? key}) {
    final scopedController = DebugSettingsActionScope.maybeControllerOf(
      context,
    );
    return DebugSettingsScreen(
      key: key,
      dataController: scopedController ??
          MemexRouterDebugSettingsDataController(context.read<MemexRouter>()),
    );
  }

  final DebugSettingsDataController dataController;
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  State<DebugSettingsScreen> createState() => _DebugSettingsScreenState();
}

class _DebugSettingsScreenState extends State<DebugSettingsScreen> {
  final _logger = getLogger('DebugSettingsScreen');
  late DebugSettingsViewModel _viewModel;
  late GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey;

  @override
  void initState() {
    super.initState();
    _viewModel = DebugSettingsViewModel(dataController: widget.dataController);
    _scaffoldMessengerKey =
        widget.scaffoldMessengerKey ?? GlobalKey<ScaffoldMessengerState>();
  }

  @override
  void didUpdateWidget(DebugSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dataController != oldWidget.dataController) {
      _viewModel.dispose();
      _viewModel = DebugSettingsViewModel(
        dataController: widget.dataController,
      );
    }
    if (widget.scaffoldMessengerKey != oldWidget.scaffoldMessengerKey) {
      _scaffoldMessengerKey =
          widget.scaffoldMessengerKey ?? GlobalKey<ScaffoldMessengerState>();
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _clearToken() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UserStorage.l10n.confirmClear),
        content: Text(UserStorage.l10n.confirmClearTokenMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(UserStorage.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(UserStorage.l10n.confirm),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _viewModel.clearToken();
      if (!mounted) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.tokenCleared,
      );
      context.go(AppRoutes.userSetup);
    } catch (e, stack) {
      _logger.severe('Clear token failed: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.clearTokenFailed(e.toString()),
      );
    }
  }

  Future<void> _clearData() async {
    if (_viewModel.isClearingData) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UserStorage.l10n.clearData),
        content: Text(
          '${UserStorage.l10n.confirmClearDataMessage}\n'
          '${UserStorage.l10n.confirmClearDataKeepFactsMessage}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(UserStorage.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(UserStorage.l10n.confirmClear),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final cleared = await _viewModel.clearData();
      if (!mounted || !cleared) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.dataClearedSuccess,
      );
    } on DebugSettingsUserNotFoundException {
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.userIdNotFound,
      );
    } catch (e, stack) {
      _logger.severe('Clear data failed: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.clearDataFailed(e),
      );
    }
  }

  Future<void> _clearFailedAgentContexts() async {
    if (_viewModel.isClearingFailedAgentContexts) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UserStorage.l10n.clearFailedAgentContexts),
        content: Text(UserStorage.l10n.confirmClearFailedAgentContextsMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(UserStorage.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(UserStorage.l10n.confirmClear),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final deletedCount = await _viewModel.clearFailedAgentContexts();
      if (!mounted || deletedCount == null) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.failedAgentContextsCleared(deletedCount),
      );
    } catch (e, stack) {
      _logger.severe('Error clearing failed agent contexts: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.clearFailedAgentContextsFailed(e),
      );
    }
  }

  Future<void> _reprocessCards() async {
    if (_viewModel.isReprocessingCards) return;

    final options = await showReprocessCardsDialog(context);
    if (options == null) return;

    try {
      final created = await _viewModel.createReprocessCardsTask(options);
      if (!mounted || !created) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.reprocessCardsTaskCreated,
      );
    } on DebugSettingsUserNotFoundException {
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.userIdNotFound,
      );
    } catch (e, stack) {
      _logger.severe('Error reprocessing cards: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.createTaskFailed(e),
      );
    }
  }

  Future<void> _reprocessComments() async {
    if (_viewModel.isReprocessingComments) return;

    final options = await _showDateRangeTaskDialog(
      title: UserStorage.l10n.regenerateComments,
    );
    if (options == null) return;

    try {
      final created = await _viewModel.createReprocessCommentsTask(options);
      if (!mounted || !created) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.regenerateCommentsTaskCreated,
      );
    } on DebugSettingsUserNotFoundException {
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.userIdNotFound,
      );
    } catch (e, stack) {
      _logger.severe('Error reprocessing comments: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.createTaskFailed(e),
      );
    }
  }

  Future<void> _reprocessKnowledgeBase() async {
    if (_viewModel.isReprocessingKnowledgeBase) return;

    final options = await _showDateRangeTaskDialog(
      title: UserStorage.l10n.reprocessKnowledgeBase,
    );
    if (options == null) return;

    try {
      final created = await _viewModel.createReprocessKnowledgeBaseTask(
        options,
      );
      if (!mounted || !created) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.reprocessTaskCreated,
      );
    } on DebugSettingsUserNotFoundException {
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.userIdNotFound,
      );
    } catch (e, stack) {
      _logger.severe('Error reprocessing knowledge base: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.createTaskFailed(e),
      );
    }
  }

  Future<void> _rebuildSearchIndex() async {
    if (_viewModel.isRebuildingSearchIndex) return;

    try {
      final rebuilt = await _viewModel.rebuildSearchIndex();
      if (!mounted || !rebuilt) return;
      ToastHelper.showSuccessWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.rebuildSearchIndexSuccess,
      );
    } catch (e, stack) {
      _logger.severe('Error rebuilding search index: $e', e, stack);
      if (!mounted) return;
      ToastHelper.showErrorWithKey(
        _scaffoldMessengerKey,
        UserStorage.l10n.rebuildSearchIndexFailed,
      );
    }
  }

  Future<DebugDateRangeTaskOptions?> _showDateRangeTaskDialog({
    required String title,
  }) {
    DateTime? dateFrom;
    DateTime? dateTo;
    int? limit;

    return showDialog<DebugDateRangeTaskOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(UserStorage.l10n.selectDateRangeOptional),
                const SizedBox(height: 8),
                ListTile(
                  title: Text(UserStorage.l10n.startDate),
                  trailing: TextButton(
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (date == null) return;
                      setDialogState(() {
                        dateFrom = date;
                        if (dateTo != null && dateTo!.isBefore(date)) {
                          dateTo = date;
                        }
                      });
                    },
                    child: Text(
                      dateFrom == null
                          ? UserStorage.l10n.select
                          : DebugDateRangeTaskOptions.formatDate(dateFrom!),
                    ),
                  ),
                ),
                ListTile(
                  title: Text(UserStorage.l10n.endDate),
                  trailing: TextButton(
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: dateTo ?? DateTime.now(),
                        firstDate: dateFrom ?? DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (date == null) return;
                      setDialogState(() {
                        dateTo = date;
                      });
                    },
                    child: Text(
                      dateTo == null
                          ? UserStorage.l10n.select
                          : DebugDateRangeTaskOptions.formatDate(dateTo!),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  decoration: InputDecoration(
                    labelText: UserStorage.l10n.processLimitOptional,
                    hintText: UserStorage.l10n.leaveEmptyForAll,
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    limit = int.tryParse(value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(UserStorage.l10n.cancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  DebugDateRangeTaskOptions(
                    dateFrom: dateFrom,
                    dateTo: dateTo,
                    limit: limit,
                  ),
                );
              },
              child: Text(UserStorage.l10n.startProcessing),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: ListenableBuilder(
        listenable: _viewModel,
        builder: (context, _) {
          return DebugSettingsPage(
            onClearToken: _clearToken,
            onClearData: _clearData,
            onClearFailedAgentContexts: _clearFailedAgentContexts,
            onReprocessCards: _reprocessCards,
            onReprocessComments: _reprocessComments,
            onReprocessKnowledgeBase: _reprocessKnowledgeBase,
            onRebuildSearchIndex: _rebuildSearchIndex,
            isClearingData: _viewModel.isClearingData,
            isClearingFailedAgentContexts:
                _viewModel.isClearingFailedAgentContexts,
            isReprocessingCards: _viewModel.isReprocessingCards,
            isReprocessingComments: _viewModel.isReprocessingComments,
            isReprocessingKnowledgeBase: _viewModel.isReprocessingKnowledgeBase,
            isRebuildingSearchIndex: _viewModel.isRebuildingSearchIndex,
          );
        },
      ),
    );
  }
}
