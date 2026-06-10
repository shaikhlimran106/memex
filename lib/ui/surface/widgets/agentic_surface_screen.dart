import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memex/data/services/agentic_surface_service.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/utils/logger.dart';
import 'package:webview_flutter/webview_flutter.dart';

class AgenticSurfaceScreen extends StatefulWidget {
  const AgenticSurfaceScreen({
    super.key,
    required this.initialIntent,
  });

  final String initialIntent;

  @override
  State<AgenticSurfaceScreen> createState() => _AgenticSurfaceScreenState();
}

class _AgenticSurfaceScreenState extends State<AgenticSurfaceScreen> {
  final _logger = getLogger('AgenticSurfaceScreen');
  final _editController = TextEditingController();
  final _focusNode = FocusNode();

  late final WebViewController _webViewController;
  AgenticSurfaceDraft? _draft;
  String _statusText = '正在生成 Surface...';
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url;
            if (url == 'about:blank' ||
                url.startsWith('data:') ||
                url.startsWith('file:')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..addJavaScriptChannel(
        'MemexBridge',
        onMessageReceived: _handleBridgeMessage,
      );
    _updateSurface(widget.initialIntent);
  }

  @override
  void dispose() {
    _editController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _updateSurface(String intent) async {
    final trimmed = intent.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _isUpdating = true;
      _statusText = '正在更新 Surface...';
    });

    try {
      final draft = await AgenticSurfaceService.instance.createOrUpdateSurface(
        intent: trimmed,
      );
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _statusText = draft.summary;
        _editController.clear();
      });
      await _webViewController.loadHtmlString(_wrapHtml(draft.html));
    } catch (e, stackTrace) {
      _logger.severe('Failed to update agentic surface', e, stackTrace);
      if (!mounted) return;
      setState(() => _statusText = 'Surface 更新失败：$e');
    } finally {
      if (mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  Future<void> _handleBridgeMessage(JavaScriptMessage message) async {
    String? callbackId;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map<String, dynamic>) {
        throw ArgumentError('Bridge payload must be an object.');
      }

      callbackId = decoded['id']?.toString();
      final name = decoded['name']?.toString();
      final rawArgs = decoded['args'];
      if (callbackId == null || callbackId.isEmpty) {
        throw ArgumentError('Bridge payload missing id.');
      }
      if (name == null || name.isEmpty) {
        throw ArgumentError('Bridge payload missing capability name.');
      }
      final args = rawArgs is Map
          ? Map<String, dynamic>.from(rawArgs)
          : <String, dynamic>{};

      Map<String, dynamic> result;
      if (name == 'update_surface') {
        final instruction = args['instruction']?.toString().trim() ?? '';
        if (instruction.isEmpty) {
          throw ArgumentError('instruction is required.');
        }
        await _updateSurface(instruction);
        result = {
          'ok': true,
          'message': 'Surface 已更新。',
          'summary': _draft?.summary,
        };
      } else {
        result = await AgenticSurfaceService.instance.callCapability(
          name: name,
          args: args,
        );
      }

      if (!mounted) return;
      setState(() {
        _statusText = result['message']?.toString() ?? '$name 已完成';
      });
      await _resolveBridgeCall(callbackId, result);
    } catch (e, stackTrace) {
      _logger.warning('Agentic surface bridge call failed', e, stackTrace);
      if (callbackId != null && mounted) {
        await _rejectBridgeCall(callbackId, e.toString());
      }
      if (mounted) {
        setState(() => _statusText = '操作失败：$e');
      }
    }
  }

  Future<void> _resolveBridgeCall(
    String callbackId,
    Map<String, dynamic> result,
  ) {
    return _webViewController.runJavaScript(
      'window.__memexResolve(${jsonEncode(callbackId)}, ${jsonEncode(result)});',
    );
  }

  Future<void> _rejectBridgeCall(String callbackId, String error) {
    return _webViewController.runJavaScript(
      'window.__memexReject(${jsonEncode(callbackId)}, ${jsonEncode(error)});',
    );
  }

  String _wrapHtml(String html) {
    const bridge = '''
<script>
  (function() {
    let nextId = 1;
    const pending = {};
    window.__memexResolve = function(id, result) {
      if (!pending[id]) return;
      pending[id].resolve(result);
      delete pending[id];
    };
    window.__memexReject = function(id, error) {
      if (!pending[id]) return;
      pending[id].reject(new Error(error || 'Memex capability failed'));
      delete pending[id];
    };
    window.memex = {
      call: function(name, args) {
        const id = String(nextId++);
        return new Promise(function(resolve, reject) {
          pending[id] = { resolve: resolve, reject: reject };
          MemexBridge.postMessage(JSON.stringify({
            id: id,
            name: name,
            args: args || {}
          }));
        });
      }
    };
  })();
</script>
''';
    if (html.contains('</head>')) {
      return html.replaceFirst('</head>', '$bridge</head>');
    }
    return '$bridge$html';
  }

  void _submitEdit() {
    final instruction = _editController.text.trim();
    if (instruction.isEmpty || _isUpdating) return;
    _focusNode.unfocus();
    _updateSurface(instruction);
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8FAFC),
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              draft?.title ?? 'Agentic Surface',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              _statusText,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _webViewController),
                if (_isUpdating)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x66F8FAFC),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _editController,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitEdit(),
                      decoration: InputDecoration(
                        hintText: '告诉 Memex 怎么改这个页面...',
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    onPressed: _isUpdating ? null : _submitEdit,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.textPrimary,
                      disabledBackgroundColor: AppColors.textTertiary,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
