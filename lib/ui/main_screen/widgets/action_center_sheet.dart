import 'package:flutter/material.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/data/services/card_attachment_service.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/ui/card_attachments/card_attachment_data.dart';
import 'package:memex/ui/card_attachments/card_attachment_factory.dart';
import 'package:memex/ui/core/widgets/agent_logo_loading.dart';

class ActionCenterSheet extends StatefulWidget {
  const ActionCenterSheet({super.key});

  @override
  State<ActionCenterSheet> createState() => _ActionCenterSheetState();
}

class _ActionCenterSheetState extends State<ActionCenterSheet> {
  List<CardAttachmentData>? _items;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
    EventBusService.instance.addHandler(
      EventBusMessageType.attachmentsChanged,
      _onAttachmentsChanged,
    );
  }

  @override
  void dispose() {
    EventBusService.instance.removeHandler(
      EventBusMessageType.attachmentsChanged,
      _onAttachmentsChanged,
    );
    super.dispose();
  }

  void _onAttachmentsChanged(EventBusMessage message) {
    _load();
  }

  Future<void> _load() async {
    final items = await CardAttachmentService.instance.getPendingAttachments();
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!AppDatabase.isInitialized) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
        minHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.assignment_turned_in,
                        size: 20,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      UserStorage.l10n.actionCenterTitle,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textSecondary),
                  onPressed: () => Navigator.pop(context),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Content
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: AgentLogoLoading());
    }

    final items = _items ?? const [];

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.inbox_rounded,
              size: 64,
              color: Color(0xFFCBD5E1),
            ),
            const SizedBox(height: 16),
            Text(
              UserStorage.l10n.noPendingActions,
              style: const TextStyle(
                fontSize: 16,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        return KeyedSubtree(
          key: ValueKey(item.id),
          child: CardAttachmentFactory.build(item),
        );
      },
    );
  }
}
