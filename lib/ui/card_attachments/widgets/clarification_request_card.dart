import 'package:flutter/material.dart';
import 'package:memex/data/services/clarification_request_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/user_storage.dart';

class ClarificationRequestCard extends StatefulWidget {
  const ClarificationRequestCard({
    super.key,
    required this.request,
    required this.service,
  });

  final ClarificationRequest request;
  final ClarificationRequestService service;

  @override
  State<ClarificationRequestCard> createState() =>
      _ClarificationRequestCardState();
}

class _ClarificationRequestCardState extends State<ClarificationRequestCard> {
  static const _syntheticOtherId = '__other__';
  static const _syntheticUncertainId = '__uncertain__';

  final Set<String> _selectedOptionIds = {};
  final TextEditingController _textController = TextEditingController();
  final FocusNode _customAnswerFocusNode = FocusNode();
  List<Map<String, dynamic>> _customAnswerOptions = const [];
  bool _isCustomAnswerMode = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _customAnswerFocusNode.addListener(_handleCustomAnswerFocusChanged);
  }

  @override
  void dispose() {
    _customAnswerFocusNode
      ..removeListener(_handleCustomAnswerFocusChanged)
      ..dispose();
    _textController.dispose();
    super.dispose();
  }

  void _handleCustomAnswerFocusChanged() {
    if (_customAnswerFocusNode.hasFocus || !_isCustomAnswerMode) return;
    if (_textController.text.trim().isNotEmpty || _isProcessing) return;
    _collapseCustomAnswerInput();
  }

  Future<void> _submit({
    List<Map<String, dynamic>>? selectedOptions,
    String? text,
  }) async {
    if (_isProcessing) return;

    final options = selectedOptions ?? const <Map<String, dynamic>>[];
    final isCustomAnswer = options.any(_requiresCustomAnswer);
    final typedText = text?.trim();

    if (isCustomAnswer && (typedText == null || typedText.isEmpty)) {
      ToastHelper.showInfo(context, UserStorage.l10n.clarificationTextRequired);
      return;
    }

    final answerText = typedText ??
        options
            .map((option) =>
                _nonEmptyString(option['label']) ??
                _nonEmptyString(option['value']))
            .whereType<String>()
            .join(', ');

    if (answerText.trim().isEmpty) return;

    setState(() => _isProcessing = true);
    final ok = await widget.service.answerRequest(widget.request.id, {
      'option_ids': options.map((e) => e['id']).toList(),
      'text': answerText,
      'is_custom_answer': isCustomAnswer,
      'is_uncertain': options.any(_isUncertainOption),
    });

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (ok) {
      ToastHelper.showSuccess(context, UserStorage.l10n.answerSaved);
    } else {
      ToastHelper.showError(context, UserStorage.l10n.saveFailed(''));
    }
  }

  String? _nonEmptyString(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  bool _requiresCustomAnswer(Map<String, dynamic> option) {
    final normalized = _normalizedOptionText(option);
    return normalized.contains('other') ||
        normalized.contains('custom') ||
        normalized.contains('manual') ||
        normalized.contains('type in') ||
        normalized.contains('write in') ||
        normalized.contains('none of the above') ||
        normalized.contains('not listed') ||
        normalized.contains('其他') ||
        normalized.contains('其它') ||
        normalized.contains('手动') ||
        normalized.contains('手工') ||
        normalized.contains('自己输入') ||
        normalized.contains('自行输入') ||
        normalized.contains('另一个') ||
        normalized.contains('以上都不是') ||
        normalized.contains('都不是') ||
        normalized.contains('不在其中');
  }

  bool _isUncertainOption(Map<String, dynamic> option) {
    final normalized = _normalizedOptionText(option);
    return normalized.contains('unknown') ||
        normalized.contains('unsure') ||
        normalized.contains('not sure') ||
        normalized.contains('unclear') ||
        normalized.contains('prefer not to say') ||
        normalized.contains('no update') ||
        normalized.contains('no news') ||
        normalized.contains('不知道') ||
        normalized.contains('不确定') ||
        normalized.contains('不方便') ||
        normalized.contains('不想说') ||
        normalized.contains('不愿') ||
        normalized.contains('暂时不说') ||
        normalized.contains('还没有消息') ||
        normalized.contains('没有消息') ||
        normalized.contains('无法判断') ||
        normalized.contains('说不清');
  }

  String _normalizedOptionText(Map<String, dynamic> option) {
    return [option['id'], option['label'], option['value']]
        .whereType<Object>()
        .map((e) => e.toString().toLowerCase())
        .join(' ');
  }

  Future<void> _dismiss() async {
    setState(() => _isProcessing = true);
    await widget.service.dismissRequest(widget.request.id);
    if (mounted) setState(() => _isProcessing = false);
  }

  void _openCustomAnswerInput(List<Map<String, dynamic>> options) {
    setState(() {
      _customAnswerOptions = options;
      _isCustomAnswerMode = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCustomAnswerMode) return;
      _customAnswerFocusNode.requestFocus();
    });
  }

  void _collapseCustomAnswerInput() {
    if (!mounted) return;
    setState(() {
      for (final option in _customAnswerOptions) {
        _selectedOptionIds.remove(option['id']?.toString());
      }
      _customAnswerOptions = const [];
      _isCustomAnswerMode = false;
      _textController.clear();
    });
  }

  List<Map<String, dynamic>> _options() {
    final decodedOptions = widget.service.decodeOptions(widget.request);
    final options = decodedOptions.isEmpty &&
            widget.request.responseType == ClarificationResponseType.confirm
        ? [
            {'id': 'yes', 'label': UserStorage.l10n.yes, 'value': 'yes'},
            {'id': 'no', 'label': UserStorage.l10n.no, 'value': 'no'},
          ]
        : List<Map<String, dynamic>>.from(decodedOptions);

    if (options.isEmpty ||
        widget.request.responseType == ClarificationResponseType.shortText) {
      return options;
    }

    if (!options.any(_isUncertainOption)) {
      options.add({
        'id': _syntheticUncertainId,
        'label': UserStorage.l10n.clarificationNotSure,
        'value': UserStorage.l10n.clarificationNotSure,
      });
    }

    final canUseCustomAnswer = widget.request.responseType ==
            ClarificationResponseType.singleChoice ||
        widget.request.responseType == ClarificationResponseType.multiChoice;
    if (canUseCustomAnswer && !options.any(_requiresCustomAnswer)) {
      options.add({
        'id': _syntheticOtherId,
        'label': UserStorage.l10n.clarificationOtherAnswer,
        'value': '',
      });
    }

    return options;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final options = _options();
    final responseType = widget.request.responseType;
    final isAnswered =
        widget.request.status != ClarificationRequestStatus.pending;
    final answerSummary = _answerSummary(options);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color:
                    (isAnswered ? colorScheme.primary : const Color(0xFF5B6CFF))
                        .withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isAnswered
                    ? Icons.check_circle_outline_rounded
                    : Icons.help_outline_rounded,
                size: 18,
                color:
                    isAnswered ? colorScheme.primary : const Color(0xFF5B6CFF),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isAnswered
                    ? UserStorage.l10n.clarificationAnswered
                    : UserStorage.l10n.clarificationNeeded,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isAnswered
                          ? colorScheme.primary
                          : const Color(0xFF5B6CFF),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text(
            widget.request.question,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
          ),
          if (widget.request.reason != null &&
              widget.request.reason!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              widget.request.reason!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
            ),
          ],
          if (isAnswered)
            _buildAnsweredSummary(context, answerSummary)
          else ...[
            if (responseType == ClarificationResponseType.shortText)
              _buildTextAnswer(context)
            else if (responseType == ClarificationResponseType.multiChoice)
              _buildMultiChoice(context, options)
            else
              _buildSingleChoice(context, options),
            if (_isCustomAnswerMode) _buildCustomAnswerInput(context),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isProcessing ? null : _dismiss,
                  child: Text(UserStorage.l10n.ignore),
                ),
                if (responseType == ClarificationResponseType.multiChoice ||
                    responseType == ClarificationResponseType.shortText ||
                    _isCustomAnswerMode) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            if (responseType ==
                                ClarificationResponseType.shortText) {
                              _submit(text: _textController.text);
                            } else if (_isCustomAnswerMode) {
                              final selected = responseType ==
                                      ClarificationResponseType.multiChoice
                                  ? options
                                      .where((o) => _selectedOptionIds
                                          .contains(o['id']?.toString()))
                                      .toList()
                                  : _customAnswerOptions;
                              _submit(
                                  selectedOptions: selected,
                                  text: _textController.text);
                            } else {
                              final selected = options
                                  .where((o) => _selectedOptionIds
                                      .contains(o['id']?.toString()))
                                  .toList();
                              _submit(selectedOptions: selected);
                            }
                          },
                    child: _isProcessing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(UserStorage.l10n.save),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _answerSummary(List<Map<String, dynamic>> options) {
    final answerData = widget.service.decodeAnswerData(widget.request);
    final text = _nonEmptyString(answerData['text']);
    if (text != null) return text;
    final selectedIds =
        (answerData['option_ids'] as List?)?.map((e) => e.toString()).toSet() ??
            const <String>{};
    return options
        .where((o) => selectedIds.contains(o['id']?.toString()))
        .map((o) => _nonEmptyString(o['label']) ?? _nonEmptyString(o['value']))
        .whereType<String>()
        .join(', ');
  }

  Widget _buildAnsweredSummary(BuildContext context, String answerSummary) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_rounded, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            answerSummary.isEmpty
                ? UserStorage.l10n.clarificationAnswered
                : UserStorage.l10n.clarificationAnswerPrefix(answerSummary),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ]),
    );
  }

  Widget _buildSingleChoice(
      BuildContext context, List<Map<String, dynamic>> options) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: options.map((option) {
          final label = option['label']?.toString() ?? '';
          return FilledButton.tonal(
            onPressed: _isProcessing
                ? null
                : () {
                    if (_requiresCustomAnswer(option)) {
                      _openCustomAnswerInput([option]);
                      return;
                    }
                    _submit(selectedOptions: [option]);
                  },
            child: Text(label),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMultiChoice(
      BuildContext context, List<Map<String, dynamic>> options) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: options.map((option) {
          final id = option['id']?.toString() ?? '';
          final label = option['label']?.toString() ?? '';
          return FilterChip(
            label: Text(label),
            selected: _selectedOptionIds.contains(id),
            onSelected: _isProcessing
                ? null
                : (selected) {
                    setState(() {
                      if (selected && _isUncertainOption(option)) {
                        _selectedOptionIds
                          ..clear()
                          ..add(id);
                      } else {
                        _selectedOptionIds.removeAll(options
                            .where(_isUncertainOption)
                            .map((o) => o['id']?.toString())
                            .whereType<String>());
                        if (selected) {
                          _selectedOptionIds.add(id);
                        } else {
                          _selectedOptionIds.remove(id);
                        }
                      }
                      final sel = options
                          .where((o) =>
                              _selectedOptionIds.contains(o['id']?.toString()))
                          .toList();
                      _customAnswerOptions =
                          sel.where(_requiresCustomAnswer).toList();
                      _isCustomAnswerMode = _customAnswerOptions.isNotEmpty;
                      if (!_isCustomAnswerMode) _textController.clear();
                    });
                    if (_isCustomAnswerMode) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted || !_isCustomAnswerMode) return;
                        _customAnswerFocusNode.requestFocus();
                      });
                    }
                  },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTextAnswer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: TextField(
        controller: _textController,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          hintText: UserStorage.l10n.clarificationTextHint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildCustomAnswerInput(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: _textController,
        focusNode: _customAnswerFocusNode,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          hintText: UserStorage.l10n.clarificationTextHint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
    );
  }
}
