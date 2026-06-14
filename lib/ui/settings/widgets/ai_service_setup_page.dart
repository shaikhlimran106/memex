import 'dart:async';

import 'package:flutter/material.dart';
import 'package:memex/config/app_config.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/domain/models/llm_config.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/ui/settings/view_models/ai_service_setup_viewmodel.dart';
import 'package:memex/ui/settings/widgets/agent_config_list_page.dart';
import 'package:memex/ui/settings/widgets/location_context_settings_page.dart';
import 'package:memex/ui/settings/widgets/memex_auth_section.dart';
import 'package:memex/ui/settings/widgets/model_config_list_page.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/user_storage.dart';

class AiServiceSetupPage extends StatefulWidget {
  const AiServiceSetupPage({
    super.key,
    this.onComplete,
    this.onboardingMode = false,
    this.viewModel,
  });

  final VoidCallback? onComplete;
  final bool onboardingMode;
  final AiServiceSetupViewModel? viewModel;

  @override
  State<AiServiceSetupPage> createState() => _AiServiceSetupPageState();
}

class _AiServiceSetupPageState extends State<AiServiceSetupPage> {
  late final AiServiceSetupViewModel _viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel =
        widget.viewModel ?? AiServiceSetupViewModel(router: MemexRouter());
    unawaited(_viewModel.loadModelRoles());
  }

  @override
  void dispose() {
    if (_ownsViewModel) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  Future<void> _saveMemexService({
    bool finish = true,
    bool showToast = true,
  }) async {
    if (!_viewModel.hasReadyCredentials || _viewModel.isSaving) return;
    try {
      final saved = await _viewModel.saveMemexService();
      if (!saved) return;
      if (!mounted) return;
      if (showToast) {
        ToastHelper.showSuccess(context, UserStorage.l10n.aiServiceReadyToast);
      }
      if (!finish) return;
      widget.onComplete?.call();
      if (widget.onComplete == null && mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ToastHelper.showError(context, e);
      }
    }
  }

  Future<void> _clearMemexService() async {
    try {
      await _viewModel.clearMemexService();
    } catch (e) {
      if (mounted) {
        ToastHelper.showError(context, e);
      }
    }
  }

  Future<void> _showMemexServiceSetup() async {
    try {
      await _viewModel.showMemexServiceSetup();
    } catch (e) {
      if (mounted) {
        ToastHelper.showError(context, e);
      }
    }
  }

  Future<void> _openAdvancedConfig() async {
    final configured = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => ModelConfigListPage(
          popOnConfigSaved: widget.onboardingMode,
          autoOpenFirstConfig: true,
        ),
      ),
    );
    if (mounted) {
      await _viewModel.loadModelRoles(showLoading: false);
    }
    if (configured == true && mounted && widget.onboardingMode) {
      widget.onComplete?.call();
      if (widget.onComplete == null) {
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<void> _openAdvancedAgentConfig() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (context) => const AgentConfigListPage()),
    );
    if (mounted) {
      await _viewModel.loadModelRoles(showLoading: false);
    }
  }

  Future<void> _openLocationSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => const LocationContextSettingsPage(),
      ),
    );
  }

  Future<void> _updateTextModel(String? configKey) async {
    if (configKey == null || _viewModel.isUpdatingTextModel) return;
    try {
      await _viewModel.setTextModel(configKey);
      if (mounted) {
        ToastHelper.showSuccess(context, UserStorage.l10n.modelSlotUpdated);
      }
    } catch (e) {
      if (mounted) ToastHelper.showError(context, e);
    }
  }

  Future<void> _updateVisionModel(String? configKey) async {
    if (configKey == null || _viewModel.isUpdatingVisionModel) return;
    try {
      await _viewModel.setVisionModel(configKey);
      if (mounted) {
        ToastHelper.showSuccess(context, UserStorage.l10n.modelSlotUpdated);
      }
    } catch (e) {
      if (mounted) ToastHelper.showError(context, e);
    }
  }

  Future<void> _updateUseLocalSpeechToText(bool value) async {
    try {
      await _viewModel.setUseLocalSpeechToText(value);
    } catch (e) {
      if (mounted) ToastHelper.showError(context, e);
    }
  }

  void _skip() {
    widget.onComplete?.call();
    if (widget.onComplete == null) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = UserStorage.l10n;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFFF9F9FC),
          appBar: AppBar(
            backgroundColor: const Color(0xFFF9F9FC),
            surfaceTintColor: const Color(0xFFF9F9FC),
            elevation: 0,
            automaticallyImplyLeading: !widget.onboardingMode,
            title: widget.onboardingMode ? null : Text(l10n.aiModelHubTitle),
            actions: [
              if (widget.onboardingMode)
                TextButton(
                  onPressed: _viewModel.isSaving ? null : _skip,
                  child: Text(l10n.skipForNow),
                ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
                  children: [
                    _buildSetupHeader(),
                    const SizedBox(height: 22),
                    _buildModelRolesSection(),
                    const SizedBox(height: 14),
                    _buildSetupOptions(),
                    const SizedBox(height: 14),
                    _buildRelatedCapabilitiesSection(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSetupHeader() {
    final l10n = UserStorage.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.memory_rounded,
              color: AppColors.primary,
              size: 24,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            l10n.aiModelHubTitle,
            style: const TextStyle(
              fontSize: 28,
              height: 1.15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1C1E),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.aiModelHubSubtitle,
            style: const TextStyle(
              fontSize: 15,
              height: 1.55,
              color: Color(0xFF454655),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              height: 1.25,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1C1E),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Color(0xFF5F6272),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelRolesSection() {
    if (_viewModel.isRoleLoading || _viewModel.roleSelection == null) {
      return _buildOptionCard(
        icon: Icons.tune_rounded,
        iconColor: AppColors.primary,
        title: UserStorage.l10n.modelRolesTitle,
        description: UserStorage.l10n.modelRolesDescription,
        child: const SizedBox(
          height: 48,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    final selection = _viewModel.roleSelection!;

    return _buildOptionCard(
      icon: Icons.tune_rounded,
      iconColor: AppColors.primary,
      title: UserStorage.l10n.modelRolesTitle,
      description: UserStorage.l10n.modelRolesDescription,
      child: Column(
        children: [
          _buildModelRolePicker(
            key: const ValueKey('ai-model-text-slot'),
            dropdownKey: const ValueKey('ai-model-text-slot-dropdown'),
            icon: Icons.notes_rounded,
            title: UserStorage.l10n.textModelRoleTitle,
            description: UserStorage.l10n.textModelRoleDescription,
            value: _viewModel.textConfig?.key,
            isUpdating: _viewModel.isUpdatingTextModel,
            onChanged: _updateTextModel,
          ),
          const SizedBox(height: 14),
          _buildModelRolePicker(
            key: const ValueKey('ai-model-vision-slot'),
            dropdownKey: const ValueKey('ai-model-vision-slot-dropdown'),
            icon: Icons.photo_library_outlined,
            title: UserStorage.l10n.visionModelRoleTitle,
            description: UserStorage.l10n.visionModelRoleDescription,
            value: selection.visionConfigKey ??
                AiServiceSetupViewModel.followTextSelectionValue,
            includeFollowText: true,
            isUpdating: _viewModel.isUpdatingVisionModel,
            onChanged: _updateVisionModel,
          ),
          if (_viewModel.shouldWarnVision) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: Color(0xFFD97706),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    UserStorage.l10n.visionModelNonMultimodalWarning,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (!_viewModel.hasConfiguredModelOptions) ...[
            const SizedBox(height: 10),
            Text(
              UserStorage.l10n.noConfiguredModelOptions,
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Color(0xFF757687),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModelRolePicker({
    required Key key,
    required Key dropdownKey,
    required IconData icon,
    required String title,
    required String description,
    required String? value,
    required bool isUpdating,
    required ValueChanged<String?> onChanged,
    bool includeFollowText = false,
  }) {
    final dropdownValue = _dropdownValueFor(value, includeFollowText);

    return Container(
      key: key,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1C1E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Color(0xFF5F6272),
                      ),
                    ),
                  ],
                ),
              ),
              if (isUpdating)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: dropdownKey,
            initialValue: dropdownValue,
            isExpanded: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            items: _buildModelRoleDropdownItems(includeFollowText),
            onChanged: _viewModel.hasSelectableModels && !isUpdating
                ? onChanged
                : null,
          ),
        ],
      ),
    );
  }

  String? _dropdownValueFor(String? value, bool includeFollowText) {
    if (includeFollowText &&
        value == AiServiceSetupViewModel.followTextSelectionValue) {
      return AiServiceSetupViewModel.followTextSelectionValue;
    }
    if (value != null &&
        _viewModel.llmConfigs.any((config) => config.key == value)) {
      return value;
    }
    if (includeFollowText) {
      return AiServiceSetupViewModel.followTextSelectionValue;
    }
    if (_viewModel.llmConfigs.isEmpty) return null;
    return _viewModel.llmConfigs.first.key;
  }

  List<DropdownMenuItem<String>> _buildModelRoleDropdownItems(
    bool includeFollowText,
  ) {
    final items = <DropdownMenuItem<String>>[];
    if (includeFollowText) {
      items.add(
        DropdownMenuItem<String>(
          value: AiServiceSetupViewModel.followTextSelectionValue,
          child: Text(UserStorage.l10n.followTextModel),
        ),
      );
    }

    for (final config in _viewModel.llmConfigs) {
      items.add(
        DropdownMenuItem<String>(
          value: config.key,
          enabled: config.isValid,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _modelConfigLabel(config),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (LLMConfig.isKnownMultimodal(config.type, config.modelId))
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    UserStorage.l10n.visionBadge,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (!config.isValid)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: Color(0xFFD97706),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return items;
  }

  String _modelConfigLabel(LLMConfig config) {
    final provider = LLMConfig.displayName(config.type);
    return '${config.key} / $provider / ${config.modelId}';
  }

  Widget _buildRelatedCapabilitiesSection() {
    return _buildOptionCard(
      icon: Icons.hub_outlined,
      iconColor: const Color(0xFF006397),
      title: UserStorage.l10n.relatedAiCapabilitiesTitle,
      description: UserStorage.l10n.relatedAiCapabilitiesDescription,
      child: Column(
        children: [
          _buildActionTile(
            icon: Icons.people_outline,
            title: UserStorage.l10n.advancedAgentModelAssignments,
            subtitle: UserStorage.l10n.openAdvancedAgentModelAssignments,
            onTap: _openAdvancedAgentConfig,
          ),
          const Divider(height: 18),
          _buildActionTile(
            icon: Icons.my_location_outlined,
            title: UserStorage.l10n.locationProviderSettings,
            subtitle: UserStorage.l10n.locationContextDescription,
            onTap: _openLocationSettings,
          ),
          const Divider(height: 18),
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              key: const ValueKey('ai-service-speech-local-switch'),
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(
                Icons.graphic_eq,
                color: AppColors.primary,
                size: 22,
              ),
              title: Text(
                UserStorage.l10n.speechProviderSettings,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1C1E),
                ),
              ),
              subtitle: Text(
                UserStorage.l10n.useLocalSpeechToTextDesc,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Color(0xFF5F6272),
                ),
              ),
              value: _viewModel.useLocalSpeechToText,
              onChanged: _updateUseLocalSpeechToText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: AppColors.primary, size: 22),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1C1E),
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            height: 1.35,
            color: Color(0xFF5F6272),
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  Widget _buildSetupOptions() {
    return Column(
      children: [
        _buildSectionHeader(
          title: UserStorage.l10n.modelConnectionsTitle,
          description: UserStorage.l10n.modelConnectionsDescription,
        ),
        if (AppConfig.enableMemexModelService) ...[
          const SizedBox(height: 12),
          _buildMemexServiceCard(),
        ],
        const SizedBox(height: 14),
        _buildCustomModelCard(),
      ],
    );
  }

  Widget _buildOptionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E2E5)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1C1E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(
              fontSize: 14,
              height: 1.55,
              color: Color(0xFF454655),
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildCustomModelCard() {
    final l10n = UserStorage.l10n;
    return _buildOptionCard(
      icon: Icons.key_rounded,
      iconColor: const Color(0xFF006397),
      title: l10n.aiServiceCustomApiRouteTitle,
      description: l10n.aiServiceCustomModelDescription,
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey('ai-model-custom-config-button'),
          onPressed: _openAdvancedConfig,
          iconAlignment: IconAlignment.end,
          label: Text(l10n.advancedModelConfiguration),
          icon: const Icon(Icons.chevron_right_rounded, size: 20),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMemexServiceCard() {
    final l10n = UserStorage.l10n;
    return _buildOptionCard(
      icon: Icons.auto_awesome_rounded,
      iconColor: AppColors.primary,
      title: l10n.aiServiceMemexRouteTitle,
      description: l10n.aiServiceSettingsDescription,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_viewModel.showMemexSetup) ...[
            SizedBox(
              height: 48,
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    (_viewModel.isSaving || _viewModel.isMemexConfigLoading)
                        ? null
                        : _showMemexServiceSetup,
                iconAlignment: IconAlignment.end,
                icon: _viewModel.isMemexConfigLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded, size: 20),
                label: Text(l10n.enableAiService),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ] else ...[
            MemexAuthSection(
              topUpConfig: _viewModel.memexTopUpConfig,
              onCredentialsReady: (baseUrl, apiKey, models) {
                _viewModel.setMemexCredentials(baseUrl, apiKey, models);
                unawaited(_saveMemexService(finish: false, showToast: false));
              },
              onLoginStateChanged: (isLoggedIn) {
                _viewModel.setMemexLoginState(isLoggedIn);
              },
              onLogout: _clearMemexService,
            ),
            if (_viewModel.isMemexLoggedIn ||
                _viewModel.hasReadyCredentials ||
                _viewModel.isSaving) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _viewModel.hasReadyCredentials && !_viewModel.isSaving
                          ? _saveMemexService
                          : null,
                  iconAlignment: IconAlignment.end,
                  icon: _viewModel.isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 22),
                  label: Text(l10n.setupModelConfigComplete),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    disabledBackgroundColor: const Color(0xFFE2E2E5),
                    disabledForegroundColor: const Color(0xFF757687),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
