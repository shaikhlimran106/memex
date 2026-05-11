import 'package:flutter/material.dart';
import 'package:memex/domain/models/settings_item.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/ui/settings/view_models/settings_search_viewmodel.dart';
import 'package:memex/utils/user_storage.dart';

/// Full-screen settings search page.
class SettingsSearchScreen extends StatefulWidget {
  const SettingsSearchScreen({super.key, required this.viewModel});

  final SettingsSearchViewModel viewModel;

  @override
  State<SettingsSearchScreen> createState() => _SettingsSearchScreenState();
}

class _SettingsSearchScreenState extends State<SettingsSearchScreen> {
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Trigger initial load (empty query shows all items)
    widget.viewModel.updateQuery('');
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.background,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: _buildSearchField(),
      ),
      body: ListenableBuilder(
        listenable: widget.viewModel,
        builder: (context, _) {
          return _buildBody();
        },
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _textController,
      autofocus: true,
      decoration: InputDecoration(
        hintText: UserStorage.l10n.settingsSearchPlaceholder,
        hintStyle: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 16,
        ),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
      style: const TextStyle(
        fontSize: 16,
        color: AppColors.textPrimary,
      ),
      onChanged: widget.viewModel.updateQuery,
    );
  }

  Widget _buildBody() {
    final results = widget.viewModel.results;

    if (widget.viewModel.query.trim().isNotEmpty && results.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        return _buildResultItem(results[index]);
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: AppColors.textTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            UserStorage.l10n.settingsSearchEmpty,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultItem(SettingsSearchResult result) {
    final item = result.item;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.viewModel.navigateToItem(context, item),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.textSecondary.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(item.icon, color: AppColors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.breadcrumb,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
