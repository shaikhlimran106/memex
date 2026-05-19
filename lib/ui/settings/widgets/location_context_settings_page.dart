import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:memex/data/services/location_context_service.dart';
import 'package:memex/domain/models/location_context_config.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/user_storage.dart';

typedef CurrentLocationContextLoader =
    Future<CurrentLocationContext> Function({bool forceRefresh});
typedef LocationPermissionRequester = Future<void> Function();
typedef LocationSettingsOpener = Future<bool> Function();

class LocationContextSettingsPage extends StatefulWidget {
  const LocationContextSettingsPage({
    super.key,
    this.loadCurrentContext,
    this.requestLocationPermission,
    this.openAppSettings,
    this.openLocationSettings,
  });

  final CurrentLocationContextLoader? loadCurrentContext;
  final LocationPermissionRequester? requestLocationPermission;
  final LocationSettingsOpener? openAppSettings;
  final LocationSettingsOpener? openLocationSettings;

  @override
  State<LocationContextSettingsPage> createState() =>
      _LocationContextSettingsPageState();
}

class _LocationContextSettingsPageState
    extends State<LocationContextSettingsPage> {
  LocationContextConfig _config = const LocationContextConfig();
  LocationContextConfig _savedConfig = const LocationContextConfig();
  late final TextEditingController _amapKeyController;
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _runningLocationAction = false;
  String? _testResult;
  CurrentLocationContext? _testContext;

  bool get _hasChanges => !_isSameConfig(_config, _savedConfig);

  @override
  void initState() {
    super.initState();
    _amapKeyController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _amapKeyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await UserStorage.getLocationContextConfig();
    if (!mounted) return;
    setState(() {
      _config = config;
      _savedConfig = config;
      _amapKeyController.text = config.amapApiKey;
      _loading = false;
    });
  }

  void _updateDraft(LocationContextConfig config) {
    setState(() => _config = config);
  }

  Future<void> _saveChanges() async {
    if (!_hasChanges || _saving) return;
    setState(() => _saving = true);

    final config = _config.copyWith(amapApiKey: _amapKeyController.text.trim());
    try {
      await UserStorage.saveLocationContextConfig(config);
      if (!mounted) return;
      setState(() {
        _config = config;
        _savedConfig = config;
        _saving = false;
        _amapKeyController.text = config.amapApiKey;
      });
      ToastHelper.showSuccess(context, UserStorage.l10n.saveSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastHelper.showError(context, UserStorage.l10n.saveFailed(e));
    }
  }

  Future<void> _testLocation() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _testContext = null;
    });
    try {
      final loader =
          widget.loadCurrentContext ??
          LocationContextService.instance.getCurrentContext;
      final context = await loader(forceRefresh: true);
      if (!mounted) return;
      setState(() {
        _testResult = _formatLocationDebugResult(context);
        _testContext = context;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _testResult = UserStorage.l10n.locationTestFailed(e.toString()),
      );
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _handleGuidanceAction(_LocationGuidanceAction action) async {
    if (_runningLocationAction) return;
    setState(() => _runningLocationAction = true);

    try {
      switch (action) {
        case _LocationGuidanceAction.requestPermission:
          final requester =
              widget.requestLocationPermission ??
              () async => Geolocator.requestPermission();
          await requester();
          if (mounted) {
            await _testLocation();
          }
        case _LocationGuidanceAction.openAppSettings:
          final opener = widget.openAppSettings ?? Geolocator.openAppSettings;
          final opened = await opener();
          if (mounted && !opened) {
            ToastHelper.showError(
              context,
              UserStorage.l10n.locationSettingsOpenFailed,
            );
          }
        case _LocationGuidanceAction.openLocationSettings:
          final opener =
              widget.openLocationSettings ?? Geolocator.openLocationSettings;
          final opened = await opener();
          if (mounted && !opened) {
            ToastHelper.showError(
              context,
              UserStorage.l10n.locationSettingsOpenFailed,
            );
          }
      }
    } catch (e) {
      if (!mounted) return;
      ToastHelper.showError(
        context,
        UserStorage.l10n.locationActionFailed(e.toString()),
      );
    } finally {
      if (mounted) {
        setState(() => _runningLocationAction = false);
      }
    }
  }

  String _formatLocationDebugResult(CurrentLocationContext context) {
    final l10n = UserStorage.l10n;
    final address = context.address;
    final summary = address?.summary(context.granularity);
    final lines = <String>[
      '${l10n.locationDebugGps}: ${context.status}',
      '${l10n.locationDebugProvider}: ${_providerLabel(_savedConfig.provider)}',
      '${l10n.locationDebugReverseGeocode}: '
          '${address == null ? l10n.locationDebugUnavailable : l10n.locationDebugOk}',
      '${l10n.locationDebugAgentContext}: '
          '${context.toAgentSystemReminderContent() == null ? l10n.locationDebugNotInjected : l10n.locationDebugInjected}',
    ];

    if (context.source.trim().isNotEmpty) {
      lines.add('${l10n.locationDebugSource}: ${context.source}');
    }
    if (summary != null && summary.isNotEmpty) {
      lines.add('${l10n.locationDebugAddressSummary}: $summary');
    }
    if (address?.fullAddress != null) {
      lines.add('${l10n.locationDebugFullAddress}: ${address!.fullAddress!}');
    }
    if (context.latitude != null && context.longitude != null) {
      lines.add(
        '${l10n.locationDebugCoordinates}: '
        '${context.latitude!.toStringAsFixed(6)}, '
        '${context.longitude!.toStringAsFixed(6)}',
      );
    }
    if (context.accuracyMeters != null) {
      lines.add(
        '${l10n.locationDebugAccuracy}: '
        '${context.accuracyMeters!.toStringAsFixed(1)}m',
      );
    }
    if (context.reason != null && context.reason!.trim().isNotEmpty) {
      lines.add('${l10n.locationDebugReason}: ${context.reason}');
    }

    return lines.join('\n');
  }

  String _providerLabel(GeocodingProvider provider) {
    switch (provider) {
      case GeocodingProvider.openStreetMap:
        return 'OpenStreetMap / Nominatim';
      case GeocodingProvider.amap:
        return UserStorage.l10n.amapProviderName;
    }
  }

  bool _isSameConfig(LocationContextConfig a, LocationContextConfig b) {
    return a.enabled == b.enabled &&
        a.provider == b.provider &&
        a.amapApiKey == b.amapApiKey &&
        a.granularity == b.granularity &&
        a.ttlMinutes == b.ttlMinutes;
  }

  Future<bool> _showDiscardDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(UserStorage.l10n.discardChangesTitle),
        content: Text(UserStorage.l10n.discardChangesMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(UserStorage.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              UserStorage.l10n.discardButton,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = UserStorage.l10n;
    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _showDiscardDialog();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        appBar: AppBar(
          title: Text(l10n.locationContextTitle),
          backgroundColor: AppColors.background,
          surfaceTintColor: AppColors.background,
        ),
        bottomNavigationBar: _loading ? null : _saveBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _section(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(
                        Icons.my_location_outlined,
                        color: AppColors.primary,
                      ),
                      title: Text(l10n.locationContextAttachTitle),
                      subtitle: Text(l10n.locationContextAttachDesc),
                      value: _config.enabled,
                      onChanged: (value) =>
                          _updateDraft(_config.copyWith(enabled: value)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _section(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.reverseGeocodingProvider,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<GeocodingProvider>(
                          key: ValueKey(_config.provider),
                          initialValue: _config.provider,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          selectedItemBuilder: (_) => [
                            const Text('OpenStreetMap / Nominatim'),
                            Text(l10n.amapProviderName),
                          ],
                          items: [
                            const DropdownMenuItem(
                              value: GeocodingProvider.openStreetMap,
                              child: Text('OpenStreetMap / Nominatim'),
                            ),
                            DropdownMenuItem(
                              value: GeocodingProvider.amap,
                              child: Text(l10n.amapProviderName),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            _updateDraft(_config.copyWith(provider: value));
                          },
                        ),
                        if (_config.provider == GeocodingProvider.amap) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _amapKeyController,
                            decoration: InputDecoration(
                              labelText: l10n.amapApiKey,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (value) => _updateDraft(
                              _config.copyWith(amapApiKey: value.trim()),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.amapGcj02Note,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _section(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.contextGranularity,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<LocationContextGranularity>(
                          key: ValueKey(_config.granularity),
                          initialValue: _config.granularity,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: LocationContextGranularity.city,
                              child: Text(l10n.granularityCity),
                            ),
                            DropdownMenuItem(
                              value: LocationContextGranularity.district,
                              child: Text(l10n.granularityDistrict),
                            ),
                            DropdownMenuItem(
                              value: LocationContextGranularity.neighborhood,
                              child: Text(l10n.granularityNeighborhood),
                            ),
                            DropdownMenuItem(
                              value: LocationContextGranularity.street,
                              child: Text(l10n.granularityStreet),
                            ),
                            DropdownMenuItem(
                              value: LocationContextGranularity.full,
                              child: Text(l10n.granularityFullAddress),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            _updateDraft(_config.copyWith(granularity: value));
                          },
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.locationFreshness,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          key: ValueKey(_config.ttlMinutes),
                          initialValue: _config.ttlMinutes,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 5,
                              child: Text(l10n.minutesShort(5)),
                            ),
                            DropdownMenuItem(
                              value: 15,
                              child: Text(l10n.minutesShort(15)),
                            ),
                            DropdownMenuItem(
                              value: 30,
                              child: Text(l10n.minutesShort(30)),
                            ),
                            DropdownMenuItem(
                              value: 60,
                              child: Text(l10n.oneHour),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            _updateDraft(_config.copyWith(ttlMinutes: value));
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _section(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton.icon(
                          onPressed: _testing ? null : _testLocation,
                          icon: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.location_searching),
                          label: Text(l10n.testCurrentLocation),
                        ),
                        if (_testContext != null) ...[
                          const SizedBox(height: 16),
                          _locationStatusFeedback(_testContext!),
                        ],
                        if (_testResult != null) ...[
                          const SizedBox(height: 12),
                          SelectableText(
                            _testResult!,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _locationStatusFeedback(CurrentLocationContext context) {
    final feedback = _feedbackFor(context);
    final details = _feedbackDetails(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(feedback.icon, color: feedback.color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    feedback.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    feedback.message,
                    style: TextStyle(color: Colors.grey[700], height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...details.map(
            (detail) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                detail,
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
            ),
          ),
        ],
        if (feedback.action != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _runningLocationAction
                ? null
                : () => _handleGuidanceAction(feedback.action!),
            icon: _runningLocationAction
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(feedback.actionIcon),
            label: Text(feedback.actionLabel!),
          ),
        ],
      ],
    );
  }

  _LocationStatusFeedback _feedbackFor(CurrentLocationContext context) {
    final l10n = UserStorage.l10n;
    final reason = (context.reason ?? '').toLowerCase();

    if (context.status == 'disabled') {
      return _LocationStatusFeedback(
        icon: Icons.location_disabled_outlined,
        color: Colors.grey,
        title: l10n.locationStatusDisabledTitle,
        message: l10n.locationStatusDisabledBody,
      );
    }
    if (reason.contains('service is disabled')) {
      return _LocationStatusFeedback(
        icon: Icons.location_off_outlined,
        color: Colors.orange,
        title: l10n.locationStatusServiceDisabledTitle,
        message: l10n.locationStatusServiceDisabledBody,
        action: _LocationGuidanceAction.openLocationSettings,
        actionIcon: Icons.settings_outlined,
        actionLabel: l10n.openLocationSettingsButton,
      );
    }
    if (reason.contains('permanently denied')) {
      return _LocationStatusFeedback(
        icon: Icons.app_settings_alt_outlined,
        color: Colors.orange,
        title: l10n.locationStatusPermissionForeverTitle,
        message: l10n.locationStatusPermissionForeverBody,
        action: _LocationGuidanceAction.openAppSettings,
        actionIcon: Icons.app_settings_alt_outlined,
        actionLabel: l10n.openAppSettingsButton,
      );
    }
    if (reason.contains('permission denied')) {
      return _LocationStatusFeedback(
        icon: Icons.location_on_outlined,
        color: AppColors.primary,
        title: l10n.locationStatusPermissionDeniedTitle,
        message: l10n.locationStatusPermissionDeniedBody,
        action: _LocationGuidanceAction.requestPermission,
        actionIcon: Icons.location_on_outlined,
        actionLabel: l10n.allowLocationPermissionButton,
      );
    }
    if (context.isFresh && _looksApproximate(context)) {
      return _LocationStatusFeedback(
        icon: Icons.adjust_outlined,
        color: Colors.orange,
        title: l10n.locationStatusApproximateTitle,
        message: l10n.locationStatusApproximateBody,
        action: _LocationGuidanceAction.openAppSettings,
        actionIcon: Icons.app_settings_alt_outlined,
        actionLabel: l10n.openAppSettingsButton,
      );
    }
    if (context.isFresh && context.address == null) {
      return _LocationStatusFeedback(
        icon: Icons.gps_fixed_outlined,
        color: Colors.orange,
        title: l10n.locationStatusGeocodeUnavailableTitle,
        message: l10n.locationStatusGeocodeUnavailableBody,
      );
    }
    if (context.isFresh) {
      return _LocationStatusFeedback(
        icon: Icons.check_circle_outline,
        color: Colors.green,
        title: l10n.locationStatusSuccessTitle,
        message: l10n.locationStatusSuccessBody,
      );
    }

    return _LocationStatusFeedback(
      icon: Icons.info_outline,
      color: Colors.orange,
      title: l10n.locationStatusUnavailableTitle,
      message: l10n.locationStatusUnavailableBody,
    );
  }

  List<String> _feedbackDetails(CurrentLocationContext context) {
    final l10n = UserStorage.l10n;
    final summary = context.address?.summary(context.granularity);
    return [
      '${l10n.locationStatusUpdatedAt}: ${_formatTimestamp(context.updatedAt)}',
      if (summary != null && summary.isNotEmpty)
        '${l10n.locationDebugAddressSummary}: $summary',
      if (context.accuracyMeters != null)
        '${l10n.locationDebugAccuracy}: '
            '${context.accuracyMeters!.toStringAsFixed(1)}m',
    ];
  }

  bool _looksApproximate(CurrentLocationContext context) {
    final accuracy = context.accuracyMeters;
    return accuracy != null && accuracy >= 500;
  }

  String _formatTimestamp(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  Widget _saveBar() {
    final l10n = UserStorage.l10n;
    final hasChanges = _hasChanges;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: AppColors.textSecondary.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: hasChanges && !_saving ? _saveChanges : null,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(hasChanges ? Icons.save_outlined : Icons.check),
            label: Text(
              _saving
                  ? '${l10n.save}...'
                  : hasChanges
                  ? l10n.save
                  : l10n.saved,
            ),
          ),
        ),
      ),
    );
  }

  Widget _section({required Widget child}) {
    final borderRadius = BorderRadius.circular(16);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: AppColors.textSecondary.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    );
  }
}

enum _LocationGuidanceAction {
  requestPermission,
  openAppSettings,
  openLocationSettings,
}

class _LocationStatusFeedback {
  const _LocationStatusFeedback({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.action,
    this.actionIcon,
    this.actionLabel,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final _LocationGuidanceAction? action;
  final IconData? actionIcon;
  final String? actionLabel;
}
