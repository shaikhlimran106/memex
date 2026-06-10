import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:memex/agent/run_mode/agent_action_approval_service.dart';
import 'package:memex/agent/run_mode/agent_run_mode.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/data/model/chat_artifact.dart';
import 'package:memex/data/model/chat_events.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/ui/core/widgets/html_webview_card.dart';
import 'package:memex/ui/timeline/widgets/timeline_card_detail_screen.dart';
import 'package:memex/data/services/photo_suggestion_service.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:memex/ui/core/widgets/agent_logo_loading.dart';
import 'package:go_router/go_router.dart';
import 'package:memex/routing/routes.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/utils/token_usage_utils.dart';

// --- Display Models ---

abstract class ChatDisplayItem {}

class UserMessageItem extends ChatDisplayItem {
  final String text;
  final List<Map<String, String>>? refs;
  final List<String> imagePaths;
  UserMessageItem(
    this.text, {
    this.refs,
    this.imagePaths = const [],
  });
}

class AIMessageItem extends ChatDisplayItem {
  String text;
  bool isStreaming;
  AIMessageItem(this.text, {this.isStreaming = false});
}

class ThinkingItem extends ChatDisplayItem {
  String text;
  bool isExpanded;
  bool isFinished;
  ThinkingItem(this.text, {this.isExpanded = true, this.isFinished = false});
}

class ToolCallItem extends ChatDisplayItem {
  final String toolName;
  final String args;
  final DateTime startedAt;
  String? result;
  bool isError;
  bool isExpanded;
  DateTime? completedAt;
  Map<String, dynamic>? metadata;

  ToolCallItem(
    this.toolName,
    this.args, {
    this.result,
    this.isError = false,
    this.isExpanded = false,
  }) : startedAt = DateTime.now();

  bool get isRunning => result == null;

  Duration? get duration {
    final finishedAt = completedAt;
    if (finishedAt == null) return null;
    return finishedAt.difference(startedAt);
  }
}

class ErrorItem extends ChatDisplayItem {
  final String error;
  ErrorItem(this.error);
}

/// Inline preview of something the agent produced (record, card, document).
class ArtifactItem extends ChatDisplayItem {
  final ChatArtifact artifact;

  /// Raw HTML captured from the producing tool call args, for mini previews
  /// of dynamic HTML cards.
  final String? html;

  ArtifactItem(this.artifact, {this.html});
}

/// Inline ask-first approval card for one pending mutating tool call.
class ApprovalRequestItem extends ChatDisplayItem {
  final AgentActionApprovalRequest request;
  String status; // 'pending' | 'approved' | 'denied'
  ApprovalRequestItem(this.request) : status = 'pending';
}

class ProcessItem extends ChatDisplayItem {
  final List<ChatDisplayItem> children = [];
  bool isExpanded;
  bool isFinished;
  ProcessItem({this.isExpanded = false, this.isFinished = false});

  List<ToolCallItem> get toolCalls =>
      children.whereType<ToolCallItem>().toList();

  List<ThinkingItem> get thinkingItems =>
      children.whereType<ThinkingItem>().toList();

  bool get hasRunningTool => toolCalls.any((tool) => tool.isRunning);

  bool get hasToolError => toolCalls.any((tool) => tool.isError);
}

const double _agentChatSheetHeightFactor = 0.75;
const BorderRadius _agentChatSheetBorderRadius = BorderRadius.vertical(
  top: Radius.circular(32),
);

@visibleForTesting
double resolveAgentChatDialogHeight(
  Size viewportSize, {
  required bool isFullScreen,
}) {
  return isFullScreen
      ? viewportSize.height
      : viewportSize.height * _agentChatSheetHeightFactor;
}

@visibleForTesting
BorderRadius resolveAgentChatDialogBorderRadius({required bool isFullScreen}) {
  return isFullScreen ? BorderRadius.zero : _agentChatSheetBorderRadius;
}

/// Agent Chat Dialog with Real-time Event Streaming
class AgentChatDialog extends StatefulWidget {
  final String? agentName;
  final String title;
  final String? initialSessionId;
  final String inputHint;
  final String scene;
  final String? sceneId;
  final List<Map<String, String>>? initialRefs;

  const AgentChatDialog({
    super.key,
    this.agentName,
    this.title = 'AI Assistant',
    this.initialSessionId,
    this.inputHint = 'Ask something...',
    this.scene = 'assistant',
    this.sceneId,
    this.initialRefs,
  });

  @override
  State<AgentChatDialog> createState() => _AgentChatDialogState();
}

class _AgentChatDialogState extends State<AgentChatDialog>
    with SingleTickerProviderStateMixin {
  final Logger _logger = getLogger('AgentChatDialog');

  // Services
  MemexRouter? _memexRouter;
  MemexRouter get _router => _memexRouter ??= MemexRouter();

  // State
  List<ChatDisplayItem> _items = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _isStreaming = false;
  bool _isLoadingAgent = false;
  ChatTokenUsageEvent? _lastTokenUsage;
  bool _isReadOnly = false;
  // Whether the user has sent at least one message in normal mode — prevents switching to read-only.
  bool _hasSentInNormalMode = false;
  bool _isFullScreen = false;
  AgentRunMode _runMode = AgentRunMode.auto;
  StreamSubscription<AgentActionApprovalRequest>? _approvalSubscription;
  bool get _isSuperAgentHome => widget.scene == 'super_agent_home';

  // Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final List<XFile> _selectedImages = [];
  final Map<String, String> _originalFilenames = {};
  StreamSubscription<ChatEvent>? _chatSubscription;

  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  bool _contextSent = false;

  @override
  void initState() {
    super.initState();
    _currentSessionId = widget.initialSessionId;

    // Animations
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();

    if (_isSuperAgentHome) {
      UserStorage.getSuperAgentRunMode().then((value) {
        if (mounted) {
          setState(() => _runMode = AgentRunMode.fromWire(value));
        }
      });
    }

    final sessionId = _currentSessionId;
    if (sessionId != null) {
      AgentActionApprovalService.instance.attachSession(sessionId);
    }
    _approvalSubscription = AgentActionApprovalService.instance.requests
        .listen(_handleApprovalRequest);

    if (_currentSessionId != null) {
      _loadSessionHistory();
    }
  }

  @override
  void dispose() {
    _chatSubscription?.cancel();
    _approvalSubscription?.cancel();
    final sessionId = _currentSessionId;
    if (sessionId != null) {
      // Denies anything still pending so a gated tool call never hangs.
      AgentActionApprovalService.instance.detachSession(sessionId);
    }
    _controller.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _handleApprovalRequest(AgentActionApprovalRequest request) {
    if (!mounted || request.sessionId != _currentSessionId) return;
    setState(() => _items.add(ApprovalRequestItem(request)));
    _scrollToBottom();
  }

  // --- Logic ---

  Future<void> _loadSessionHistory() async {
    if (_currentSessionId == null) return;
    setState(() => _isLoading = true);

    try {
      // Note: We still use MemexRouter (or directly file service via a helper) to fetch history.
      // Since ChatService doesn't expose fetchHistory yet, reusing existing endpoint logic is fine.
      final sessionData = await _router.fetchChatSessionDetail(
        _currentSessionId!,
      );
      final messagesData = sessionData['messages'] as List<dynamic>? ?? [];

      final historyItems = <ChatDisplayItem>[];
      for (var msg in messagesData) {
        final role = msg['role'] as String? ?? 'user';
        final contentList = msg['content'] as List<dynamic>? ?? [];
        final imagePaths = <String>[];
        final textParts = contentList
            .where((item) {
              if (item is Map && item['type'] == 'image_url') {
                final imageUrl = item['image_url'];
                if (imageUrl is Map) {
                  final filePath = imageUrl['filePath']?.toString();
                  if (filePath != null && filePath.isNotEmpty) {
                    imagePaths.add(_resolveDisplayImagePath(filePath));
                  }
                }
              }
              return item is Map && item['type'] == 'text';
            })
            .map((item) => item['text'] as String? ?? '')
            .where((text) => text.isNotEmpty);
        final text = textParts.join(' ');

        if (text.isNotEmpty || imagePaths.isNotEmpty) {
          if (role == 'user') {
            List<Map<String, String>>? refs;
            if (msg['refs'] != null) {
              refs = (msg['refs'] as List)
                  .map((e) => Map<String, String>.from(e as Map))
                  .toList();
            }
            historyItems.add(
              UserMessageItem(
                text.isNotEmpty
                    ? text
                    : UserStorage.l10n.attachedImagesMessage(
                        imagePaths.length,
                      ),
                refs: refs,
                imagePaths: imagePaths,
              ),
            );
          } else {
            historyItems.add(AIMessageItem(text));
          }
        }
      }

      ChatTokenUsageEvent? restoredUsage;
      if (sessionData['total_usage'] != null) {
        final usage = sessionData['total_usage'] as Map<String, dynamic>;
        final prompt = usage['prompt_tokens'] as int? ?? 0;
        final cached = usage['cached_tokens'] as int? ?? 0;
        // Recompute effectivePromptTokens from per-message usage.
        int effPrompt = 0;
        int cachedForRate = 0;
        for (final msg in messagesData) {
          final msgUsage = msg['usage'] as Map<String, dynamic>?;
          if (msgUsage == null) continue;
          final mp = msgUsage['prompt_tokens'] as int? ?? 0;
          final mc = msgUsage['cached_tokens'] as int? ?? 0;
          final sem = TokenUsageUtils.resolveFromUsageRecord(msgUsage);
          final eff = TokenUsageUtils.effectivePromptTokensOrNull(
            promptTokens: mp,
            cachedTokens: mc,
            cachedTokensIncludedInPrompt: sem,
          );
          if (eff != null) {
            effPrompt += eff;
            cachedForRate += mc;
          }
        }
        restoredUsage = ChatTokenUsageEvent(
          promptTokens: prompt,
          completionTokens: usage['completion_tokens'] as int? ?? 0,
          cachedTokens: cached,
          effectivePromptTokens: effPrompt,
          cachedTokensForRate: cachedForRate,
          totalTokens: usage['total_tokens'] as int? ?? 0,
          estimatedCost: usage['total_cost'] as double? ?? 0.0,
        );
      }

      setState(() {
        _items = historyItems;
        _lastTokenUsage = restoredUsage;
        _isLoading = false;
        // Restore read-only mode from persisted session
        final wasQuickQuery = sessionData['is_quick_query'] == true;
        _isReadOnly = wasQuickQuery;
        // If session was in normal mode (or field missing for old sessions), lock toggle
        _hasSentInNormalMode = !wasQuickQuery;
      });
      _scrollToBottom();
    } catch (e) {
      _logger.severe('Error loading history', e);
      setState(() => _isLoading = false);
      if (mounted) ToastHelper.showError(context, 'Failed to load history: $e');
    }
  }

  String _resolveDisplayImagePath(String filePath) {
    if (filePath.startsWith('/')) {
      return filePath;
    }
    return FileSystemService.instance.toAbsolutePath(filePath);
  }

  void _sendMessage(
    String message, {
    List<XFile> images = const [],
    Map<String, String>? imageOriginalFilenames,
  }) {
    if ((message.trim().isEmpty && images.isEmpty) || _isStreaming) return;

    _messageFocusNode.unfocus();
    String finalMessage = message.trim();
    final displayText = finalMessage.isNotEmpty
        ? finalMessage
        : UserStorage.l10n.attachedImagesMessage(images.length);
    List<Map<String, String>>? refs;
    if (widget.initialRefs != null && !_contextSent) {
      refs = widget.initialRefs;
      _contextSent = true;
    }

    // Lock read-only toggle once user sends in normal mode
    if (!_isSuperAgentHome && !_isReadOnly) {
      _hasSentInNormalMode = true;
    }

    setState(() {
      _items.add(
        UserMessageItem(
          displayText,
          refs: refs,
          imagePaths: images.map((image) => image.path).toList(),
        ),
      );
      _isStreaming = true;
      _messageController.clear();
      if (images.isNotEmpty) {
        _selectedImages.clear();
        _originalFilenames.clear();
      }
    });
    _scrollToBottom();

    _chatSubscription?.cancel();

    _chatSubscription = _router
        .sendMessage(
      finalMessage,
      sessionId: _currentSessionId,
      agentName: widget.agentName,
      scene: widget.scene,
      sceneId: widget.sceneId,
      refs: refs,
      images: images,
      imageOriginalFilenames: imageOriginalFilenames,
      isQuickQuery: _isSuperAgentHome
          ? _runMode == AgentRunMode.readOnly
          : _isReadOnly,
      runMode: _isSuperAgentHome ? _runMode.wireName : AgentRunMode.auto.wireName,
    )
        .listen(
      (event) {
        _handleChatEvent(event);
      },
      onError: (e) {
        setState(() {
          _items.add(ErrorItem(e.toString()));
          _isStreaming = false;
        });
        _scrollToBottom();
      },
      onDone: () {
        setState(() {
          _isStreaming = false;
          // Ensure the last AI message is marked as done
          if (_items.isNotEmpty && _items.last is AIMessageItem) {
            (_items.last as AIMessageItem).isStreaming = false;
          }
        });
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        final image = await _imagePicker.pickImage(
          source: source,
          imageQuality: 85,
        );
        if (image != null && mounted) {
          setState(() => _selectedImages.add(image));
        }
        return;
      }

      if (!mounted) return;
      final result = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          maxAssets: 9,
          requestType: RequestType.image,
          filterOptions: FilterOptionGroup(
            containsPathModified: true,
            createTimeCond: DateTimeCond.def().copyWith(ignore: true),
            updateTimeCond: DateTimeCond.def().copyWith(ignore: true),
            videoOption: const FilterOption(
              durationConstraint: DurationConstraint(
                min: Duration.zero,
                max: Duration.zero,
              ),
            ),
          ),
        ),
      );
      if (result == null) return;

      for (final asset in result) {
        final xFile = await PhotoSuggestionService.assetToXFile(asset);
        if (xFile == null) continue;
        final originalName = await asset.titleAsync;
        _originalFilenames[xFile.path] = originalName;
        if (mounted) {
          setState(() => _selectedImages.add(xFile));
        }
      }
    } catch (e) {
      if (mounted) {
        ToastHelper.showError(context, e);
      }
    }
  }

  void _removeSelectedImage(int index) {
    if (index < 0 || index >= _selectedImages.length) return;
    setState(() {
      _originalFilenames.remove(_selectedImages[index].path);
      _selectedImages.removeAt(index);
    });
  }

  void _handleSuperAgentSubmit() {
    _sendMessage(
      _messageController.text,
      images: List<XFile>.from(_selectedImages),
      imageOriginalFilenames: Map<String, String>.from(_originalFilenames),
    );
  }

  void _handleChatEvent(ChatEvent event) {
    setState(() {
      if (event is ChatAgentStartedEvent) {
        _isLoadingAgent = true;
        return;
      }
      if (event is ChatAgentStoppedEvent) {
        _isLoadingAgent = false;
        return;
      }
      if (event is ChatTokenUsageEvent) {
        _lastTokenUsage = event;
        return;
      }
      if (event is ChatSessionCreatedEvent) {
        _currentSessionId = event.sessionId;
        AgentActionApprovalService.instance.attachSession(event.sessionId);
        return;
      }

      // Handle Thoughts and Tools (Grouping)
      if (event is ChatThoughtChunkEvent ||
          event is ChatToolCallEvent ||
          event is ChatToolResultEvent) {
        final processItem = _ensureProcessItem();

        if (event is ChatThoughtChunkEvent) {
          if (processItem.children.isNotEmpty &&
              processItem.children.last is ThinkingItem) {
            (processItem.children.last as ThinkingItem).text += event.text;
          } else {
            processItem.children.add(ThinkingItem(event.text));
          }
        } else if (event is ChatToolCallEvent) {
          processItem.children.add(ToolCallItem(event.toolName, event.args));
        } else if (event is ChatToolResultEvent) {
          // Find matching tool in current process item
          ToolCallItem? matchedTool;
          for (int i = processItem.children.length - 1; i >= 0; i--) {
            final item = processItem.children[i];
            if (item is ToolCallItem &&
                item.toolName == event.toolName &&
                item.result == null) {
              item.result = event.result;
              item.isError = event.isError;
              item.completedAt = DateTime.now();
              item.metadata = event.metadata;
              matchedTool = item;
              break;
            }
          }

          if (!event.isError) {
            final artifact = ChatArtifact.fromToolMetadata(event.metadata);
            if (artifact != null) {
              _items.add(
                ArtifactItem(
                  artifact,
                  html: artifact.type == ChatArtifact.typeHtmlCard
                      ? _htmlFromToolArgs(matchedTool)
                      : null,
                ),
              );
            }
          }
        }
        return; // Handled
      }

      // Handle Response (Finish Progress)
      if (event is ChatResponseChunkEvent) {
        final primary = _lastPrimaryItem();
        if (primary is ProcessItem) {
          primary.isFinished = true;
          primary.isExpanded = false; // Collapse when answer starts
        }

        if (primary is AIMessageItem) {
          primary.text += event.text;
        } else {
          _items.add(AIMessageItem(event.text, isStreaming: !event.isDone));
        }
      } else if (event is ChatErrorEvent) {
        _items.add(ErrorItem(event.error));
      }
    });
    _scrollToBottom();
  }

  /// Auxiliary items (artifacts, approval cards) interleave with the process
  /// stream; grouping logic must look past them.
  bool _isAuxiliaryItem(ChatDisplayItem item) =>
      item is ArtifactItem || item is ApprovalRequestItem;

  ChatDisplayItem? _lastPrimaryItem() {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (_isAuxiliaryItem(item)) continue;
      return item;
    }
    return null;
  }

  ProcessItem _ensureProcessItem() {
    final primary = _lastPrimaryItem();
    if (primary is ProcessItem) return primary;
    final processItem = ProcessItem();
    _items.add(processItem);
    return processItem;
  }

  String? _htmlFromToolArgs(ToolCallItem? tool) {
    if (tool == null) return null;
    try {
      final decoded = jsonDecode(tool.args);
      if (decoded is Map && decoded['html'] is String) {
        final html = (decoded['html'] as String).trim();
        return html.isEmpty ? null : html;
      }
    } catch (_) {
      // Args are not guaranteed to be valid JSON.
    }
    return null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- UI Building ---

  @override
  Widget build(BuildContext context) {
    final viewportSize = MediaQuery.of(context).size;
    final dialogHeight = resolveAgentChatDialogHeight(
      viewportSize,
      isFullScreen: _isFullScreen,
    );
    final borderRadius = resolveAgentChatDialogBorderRadius(
      isFullScreen: _isFullScreen,
    );

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Backdrop
          FadeTransition(
            opacity: _fadeAnimation,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.black.withValues(alpha: 0.2)),
            ),
          ),
          // Dialog
          SlideTransition(
            position: _slideAnimation,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                key: const ValueKey('agent_chat_dialog_container'),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: dialogHeight,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: borderRadius,
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 40,
                      offset: Offset(0, -10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: _isFullScreen,
                  bottom: false,
                  child: Column(
                    children: [
                      _buildHeader(),
                      Expanded(
                        child: Container(
                          color: Colors.white,
                          child: _isLoading
                              ? const Center(child: AgentLogoLoading())
                              : _items.isEmpty
                                  ? _buildEmptyState()
                                  : ListView.builder(
                                      controller: _scrollController,
                                      padding: const EdgeInsets.all(24),
                                      itemCount: _items.length +
                                          (_isLoadingAgent ? 1 : 0),
                                      itemBuilder: (context, index) {
                                        if (index == _items.length) {
                                          return const Padding(
                                            padding: EdgeInsets.only(
                                              bottom: 24,
                                            ),
                                            child: Row(
                                              children: [
                                                CircleAvatar(
                                                  radius: 12,
                                                  backgroundColor:
                                                      AppColors.iconBgLight,
                                                  child: SizedBox(
                                                    width: 12,
                                                    height: 12,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: AppColors.primary,
                                                    ),
                                                  ),
                                                ),
                                                SizedBox(width: 8),
                                                Text(
                                                  'Thinking...',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color:
                                                        AppColors.textTertiary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        }
                                        return _buildItem(_items[index]);
                                      },
                                    ),
                        ),
                      ),
                      _buildTokenUsageDisplay(),
                      _buildContextIndicator(),
                      _buildInput(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextIndicator() {
    if (widget.initialRefs == null ||
        widget.initialRefs!.isEmpty ||
        _contextSent) {
      return const SizedBox.shrink();
    }
    final title =
        widget.initialRefs!.first['title'] ?? UserStorage.l10n.referenceContent;

    return Container(
      width: double.infinity,
      color: const Color(0xFFF7F8FA),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.link, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              UserStorage.l10n.referenceWithTitle(title),
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    if (!_isSuperAgentHome) {
      return Center(
        child: Text(
          'Start a conversation with ${widget.title}',
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 14,
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAgentMark(size: 44),
          const SizedBox(height: 14),
          Text(
            widget.inputHint,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        border: const Border(bottom: BorderSide(color: Color(0xFFF7F8FA))),
      ),
      child: Row(
        children: [
          _buildAgentMark(size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (!_isSuperAgentHome) _buildModeChip(),
          const Spacer(),
          if (!_isSuperAgentHome)
            IconButton(
              tooltip: UserStorage.l10n.chatHistory,
              icon: const Icon(
                Icons.history,
                size: 18,
                color: AppColors.textTertiary,
              ),
              onPressed: () {
                context.push(
                  AppRoutes.chatHistory,
                  extra: {
                    'agentName': widget.agentName,
                    'title': widget.title,
                  },
                ).then((_) {
                  if (mounted) {
                    setState(() {});
                    _loadSessionHistory();
                  }
                });
              },
            ),
          IconButton(
            key: const ValueKey('agent_chat_fullscreen_toggle'),
            tooltip: _isFullScreen
                ? UserStorage.l10n.exitFullScreenTooltip
                : UserStorage.l10n.enterFullScreenTooltip,
            icon: Icon(
              _isFullScreen ? Icons.close_fullscreen : Icons.open_in_full,
              size: 18,
              color: AppColors.textTertiary,
            ),
            onPressed: () {
              setState(() {
                _isFullScreen = !_isFullScreen;
              });
              _scrollToBottom();
            },
          ),
          IconButton(
            tooltip: UserStorage.l10n.close,
            icon: const Icon(
              Icons.close,
              size: 20,
              color: AppColors.textTertiary,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentMark({double size = 24}) {
    if (_isSuperAgentHome) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.asset(
          'assets/icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }

    return const Icon(Icons.auto_awesome, size: 18, color: AppColors.primary);
  }

  Widget _buildModeChip() {
    final locked = !_isReadOnly && _hasSentInNormalMode;
    final canToggle = !locked && !_isStreaming;

    final label = _isReadOnly
        ? UserStorage.l10n.readOnlyMode
        : UserStorage.l10n.chatModeLabel;

    return GestureDetector(
      onTap: canToggle
          ? () {
              setState(() {
                _isReadOnly = !_isReadOnly;
              });
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _isReadOnly
              ? AppColors.primary.withValues(alpha: 0.08)
              : locked
                  ? const Color(0xFFF0F0F0)
                  : const Color(0xFFEEEEEE),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _isReadOnly
                    ? AppColors.primary
                    : locked
                        ? AppColors.textTertiary
                        : AppColors.textSecondary,
              ),
            ),
            if (canToggle) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.unfold_more,
                size: 12,
                color:
                    _isReadOnly ? AppColors.primary : AppColors.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    if (_isSuperAgentHome) {
      return _buildSuperAgentInput();
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFF7F8FA))),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                focusNode: _messageFocusNode,
                decoration: InputDecoration(
                  hintText: widget.inputHint,
                  hintStyle: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: (text) => _sendMessage(text),
              ),
            ),
            GestureDetector(
              onTap: () => _sendMessage(_messageController.text),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _isStreaming ? Colors.grey : AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isStreaming ? Icons.stop : Icons.arrow_upward,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuperAgentInput() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isBusy = _isStreaming;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFF7F8FA))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selectedImages.isNotEmpty) ...[
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _selectedImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  return _buildSelectedImageThumb(index);
                },
              ),
            ),
            const SizedBox(height: 10),
          ],
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _messageController,
                  focusNode: _messageFocusNode,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: widget.inputHint,
                    hintStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 15,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildInputIconButton(
                      key: const ValueKey('super_agent_camera_button'),
                      icon: Icons.camera_alt,
                      onTap:
                          isBusy ? null : () => _pickImage(ImageSource.camera),
                    ),
                    const SizedBox(width: 12),
                    _buildInputIconButton(
                      key: const ValueKey('super_agent_gallery_button'),
                      icon: Icons.photo_library,
                      onTap:
                          isBusy ? null : () => _pickImage(ImageSource.gallery),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _buildRunModeChip(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      key: const ValueKey('super_agent_publish_button'),
                      onTap: isBusy ? null : _handleSuperAgentSubmit,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: isBusy
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              UserStorage.l10n.sendLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.arrow_upward,
                              size: 17,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Run mode selector (super agent home) ---

  String _runModeLabel(AgentRunMode mode) {
    switch (mode) {
      case AgentRunMode.auto:
        return _label(en: 'Auto', zh: '自动');
      case AgentRunMode.confirm:
        return _label(en: 'Ask first', zh: '先询问');
      case AgentRunMode.readOnly:
        return _label(en: 'Read-only', zh: '只读');
    }
  }

  String _runModeDescription(AgentRunMode mode) {
    switch (mode) {
      case AgentRunMode.auto:
        return _label(
          en: 'Records, cards and documents update directly.',
          zh: '记录、卡片、文档等会直接更新。',
        );
      case AgentRunMode.confirm:
        return _label(
          en: 'Each change waits for your approval before running.',
          zh: '每个修改动作都先经你批准再执行。',
        );
      case AgentRunMode.readOnly:
        return _label(
          en: 'Answers questions only, never modifies data.',
          zh: '只查询和回答,不修改任何数据。',
        );
    }
  }

  IconData _runModeIcon(AgentRunMode mode) {
    switch (mode) {
      case AgentRunMode.auto:
        return Icons.bolt_rounded;
      case AgentRunMode.confirm:
        return Icons.verified_user_outlined;
      case AgentRunMode.readOnly:
        return Icons.visibility_outlined;
    }
  }

  void _selectRunMode(AgentRunMode mode) {
    setState(() => _runMode = mode);
    UserStorage.setSuperAgentRunMode(mode.wireName);
  }

  Widget _buildRunModeChip() {
    return GestureDetector(
      key: const ValueKey('super_agent_run_mode_chip'),
      onTap: _showRunModePicker,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _runModeIcon(_runMode),
              size: 15,
              color: _runMode == AgentRunMode.auto
                  ? AppColors.textSecondary
                  : AppColors.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                _runModeLabel(_runMode),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _runMode == AgentRunMode.auto
                      ? AppColors.textSecondary
                      : AppColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.unfold_more,
              size: 13,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  void _showRunModePicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(en: 'Run mode', zh: '运行方式'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                for (final mode in AgentRunMode.values)
                  InkWell(
                    key: ValueKey('run_mode_option_${mode.wireName}'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _selectRunMode(mode);
                    },
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: _runMode == mode
                            ? const Color(0xFFF0F4FF)
                            : const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _runMode == mode
                              ? AppColors.primary
                              : const Color(0xFFEFF2F6),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _runModeIcon(mode),
                            size: 18,
                            color: _runMode == mode
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _runModeLabel(mode),
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _runModeDescription(mode),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_runMode == mode)
                            const Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: AppColors.primary,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputIconButton({
    required Key key,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Icon(icon, size: 20, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildSelectedImageThumb(int index) {
    final image = _selectedImages[index];
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.file(
            File(image.path),
            width: 72,
            height: 72,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => _removeSelectedImage(index),
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageImageGrid(List<String> imagePaths) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: imagePaths.map((imagePath) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(
            File(imagePath),
            width: 88,
            height: 88,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 88,
              height: 88,
              color: Colors.white.withValues(alpha: 0.18),
              child: const Icon(
                Icons.broken_image_outlined,
                color: Colors.white70,
                size: 22,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildItem(ChatDisplayItem item) {
    if (item is UserMessageItem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(
                  16,
                ).copyWith(bottomRight: const Radius.circular(4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.refs != null && item.refs!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: item.refs!.map((ref) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.link,
                                  size: 12,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    ref['title'] ?? 'Reference',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  if (item.imagePaths.isNotEmpty) ...[
                    _buildMessageImageGrid(item.imagePaths),
                    const SizedBox(height: 8),
                  ],
                  SelectableText(
                    item.text,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (item is AIMessageItem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: AppColors.iconBgLight,
              child: _isSuperAgentHome
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.asset(
                        'assets/icon.png',
                        width: 16,
                        height: 16,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(
                      Icons.auto_awesome,
                      size: 12,
                      color: AppColors.primary,
                    ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(
                        16,
                      ).copyWith(topLeft: const Radius.circular(4)),
                      border: Border.all(color: const Color(0xFFF7F8FA)),
                    ),
                    child: MarkdownBody(
                      data: item.text,
                      selectable: true,
                      softLineBreak: true,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                          height: 1.5,
                        ),
                        strong: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                        em: const TextStyle(fontStyle: FontStyle.italic),
                        listBullet: const TextStyle(color: AppColors.primary),
                        code: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textPrimary,
                          backgroundColor: Color(0xFFF7F8FA),
                          fontFamily: 'monospace',
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFFF7F8FA),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquote: const TextStyle(
                          color: AppColors.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          color: const Color(0xFFF7F8FA),
                          borderRadius: BorderRadius.circular(8),
                          border: const Border(
                            left: BorderSide(
                              color: AppColors.primary,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!item.isStreaming)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, top: 6),
                      child: _CopyMessageButton(
                        text: item.text,
                        onCopied: () {
                          ToastHelper.showSuccess(
                            context,
                            UserStorage.l10n.copiedToClipboard,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (item is ProcessItem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 32), // Indent
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE6EAF2)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A0F172A),
                      blurRadius: 14,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        setState(() {
                          item.isExpanded = !item.isExpanded;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _buildProcessStatusGlyph(item),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _processTitle(item),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF0F172A),
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _processSubtitle(item),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textTertiary,
                                          height: 1.25,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                _buildProcessStatePill(item),
                                const SizedBox(width: 6),
                                Icon(
                                  item.isExpanded
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                  color: AppColors.textTertiary,
                                ),
                              ],
                            ),
                            if (item.toolCalls.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _buildToolSummaryChips(item),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (item.isExpanded)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        decoration: const BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Color(0xFFF1F5F9)),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (item.thinkingItems.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              ...item.thinkingItems.map(_buildThinkingItem),
                            ],
                            if (item.toolCalls.isNotEmpty)
                              _buildToolTraceList(item.toolCalls),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else if (item is ErrorItem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            item.error,
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
    } else if (item is ApprovalRequestItem) {
      return _buildApprovalRequestItem(item);
    } else if (item is ArtifactItem) {
      return _buildArtifactItem(item);
    }
    return const SizedBox.shrink();
  }

  // --- Ask-first approval card ---

  void _resolveApproval(ApprovalRequestItem item, {required bool approved}) {
    AgentActionApprovalService.instance.resolve(
      item.request.id,
      approved: approved,
    );
    setState(() => item.status = approved ? 'approved' : 'denied');
  }

  Widget _buildApprovalRequestItem(ApprovalRequestItem item) {
    final isPending = item.status == 'pending';
    final isApproved = item.status == 'approved';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 32),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: isPending ? const Color(0xFFFFFBEB) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isPending
                      ? const Color(0xFFFDE68A)
                      : const Color(0xFFE6EAF2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 16,
                        color: isPending
                            ? const Color(0xFFB45309)
                            : AppColors.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          isPending
                              ? _label(
                                  en:
                                      'Approve: ${_toolDisplayName(item.request.toolName)}?',
                                  zh:
                                      '是否执行:${_toolDisplayName(item.request.toolName)}?',
                                )
                              : isApproved
                                  ? _label(en: 'Approved', zh: '已允许')
                                  : _label(en: 'Denied', zh: '已拒绝'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isPending
                                ? const Color(0xFF92400E)
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                      if (!isPending)
                        Icon(
                          isApproved
                              ? Icons.check_circle_outline
                              : Icons.cancel_outlined,
                          size: 16,
                          color: isApproved
                              ? const Color(0xFF16A34A)
                              : AppColors.textTertiary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.request.summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  for (final entry in item.request.details.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${entry.key}: ${entry.value}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textTertiary,
                          height: 1.35,
                        ),
                      ),
                    ),
                  if (isPending) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: ValueKey(
                              'approval_deny_${item.request.id}',
                            ),
                            onPressed: () =>
                                _resolveApproval(item, approved: false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textSecondary,
                              side:
                                  const BorderSide(color: Color(0xFFE2E8F0)),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              _label(en: 'Deny', zh: '拒绝'),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            key: ValueKey(
                              'approval_allow_${item.request.id}',
                            ),
                            onPressed: () =>
                                _resolveApproval(item, approved: true),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.textPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              _label(en: 'Allow', zh: '允许'),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Artifact previews ---

  String _artifactHeading(ChatArtifact artifact) {
    switch (artifact.type) {
      case ChatArtifact.typeRecord:
        return _label(en: 'Record saved', zh: '已记录到时间线');
      case ChatArtifact.typeHtmlCard:
        return artifact.updated
            ? _label(en: 'Card updated', zh: '卡片已更新')
            : _label(en: 'Card created', zh: '卡片已生成');
      case ChatArtifact.typeCard:
        return _label(en: 'Card saved', zh: '卡片已保存');
      case ChatArtifact.typeFile:
        return artifact.updated
            ? _label(en: 'Document updated', zh: '文档已更新')
            : _label(en: 'Document created', zh: '文档已创建');
      case ChatArtifact.typeSystemAction:
        return artifact.kind == 'calendar'
            ? _label(en: 'Calendar event created', zh: '日历事件已创建')
            : _label(en: 'Reminder created', zh: '提醒已创建');
      case ChatArtifact.typeInsight:
        return _label(en: 'Insight saved', zh: '洞察已保存');
      default:
        return _label(en: 'Done', zh: '已完成');
    }
  }

  IconData _artifactIcon(ChatArtifact artifact) {
    switch (artifact.type) {
      case ChatArtifact.typeRecord:
        return Icons.bookmark_added_outlined;
      case ChatArtifact.typeHtmlCard:
      case ChatArtifact.typeCard:
        return Icons.auto_awesome_mosaic_outlined;
      case ChatArtifact.typeFile:
        return Icons.description_outlined;
      case ChatArtifact.typeSystemAction:
        return Icons.notifications_active_outlined;
      case ChatArtifact.typeInsight:
        return Icons.insights_outlined;
      default:
        return Icons.check_circle_outline;
    }
  }

  void _openArtifact(ChatArtifact artifact) {
    final cardId = artifact.id;
    if (cardId == null || cardId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TimelineCardDetailScreen(cardId: cardId),
      ),
    );
  }

  bool _artifactIsTappable(ChatArtifact artifact) {
    switch (artifact.type) {
      case ChatArtifact.typeRecord:
      case ChatArtifact.typeHtmlCard:
      case ChatArtifact.typeCard:
        return artifact.id != null && artifact.id!.isNotEmpty;
      default:
        return false;
    }
  }

  /// Only the most recent HTML artifacts keep a live WebView preview; older
  /// ones degrade to a flat tile to bound WebView count in long sessions.
  static const int _maxLiveHtmlPreviews = 2;

  Set<ArtifactItem> _liveHtmlPreviewItems() {
    final allowed = <ArtifactItem>{};
    for (var i = _items.length - 1;
        i >= 0 && allowed.length < _maxLiveHtmlPreviews;
        i--) {
      final item = _items[i];
      if (item is ArtifactItem &&
          item.artifact.type == ChatArtifact.typeHtmlCard &&
          item.html != null) {
        allowed.add(item);
      }
    }
    return allowed;
  }

  Widget _buildArtifactItem(ArtifactItem item) {
    final artifact = item.artifact;
    final tappable = _artifactIsTappable(artifact);
    final showHtmlPreview =
        item.html != null && _liveHtmlPreviewItems().contains(item);

    final content = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6EAF2)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _artifactIcon(artifact),
                size: 15,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _artifactHeading(artifact),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              if (tappable)
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
            ],
          ),
          if (artifact.title != null) ...[
            const SizedBox(height: 8),
            Text(
              artifact.title!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
                height: 1.3,
              ),
            ),
          ],
          if (artifact.path != null) ...[
            const SizedBox(height: 8),
            Text(
              artifact.path!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (artifact.snippet != null) ...[
            const SizedBox(height: 6),
            Text(
              artifact.snippet!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
          ],
          if (artifact.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: artifact.tags
                  .map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          if (artifact.imagePaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: artifact.imagePaths.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final path =
                      _resolveDisplayImagePath(artifact.imagePaths[index]);
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(path),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: const Color(0xFFF7F8FA),
                        child: const Icon(
                          Icons.broken_image_outlined,
                          size: 18,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          if (showHtmlPreview) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AbsorbPointer(
                child: HtmlWebViewCard(
                  html: item.html!,
                  config: const HtmlWebViewConfig(
                    initialHeight: 140,
                    minHeightThreshold: 40,
                    maxHeight: 240,
                    heightPadding: 0,
                    showContainerDecoration: true,
                    borderRadius: 14,
                    borderColor: Color(0xFFF1F5F9),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 32),
          Expanded(
            child: tappable
                ? GestureDetector(
                    onTap: () => _openArtifact(artifact),
                    child: content,
                  )
                : content,
          ),
        ],
      ),
    );
  }

  Widget _buildTokenUsageDisplay() {
    if (_lastTokenUsage == null) return const SizedBox.shrink();
    final item = _lastTokenUsage!;

    final cacheRate = TokenUsageUtils.formatCacheRateFromAggregated(
      effectivePromptTokens: item.effectivePromptTokens,
      cachedTokens: item.cachedTokensForRate,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'Tokens: ${item.totalTokens} (P:${item.promptTokens} C:${item.completionTokens} Cache:$cacheRate) • Est: \$${item.estimatedCost.toStringAsFixed(5)}',
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessStatusGlyph(ProcessItem item) {
    final color = item.hasToolError
        ? const Color(0xFFEF4444)
        : item.hasRunningTool || !item.isFinished
            ? AppColors.primary
            : const Color(0xFF10B981);
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: item.hasRunningTool || !item.isFinished
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: AppColors.primary,
                ),
              )
            : Icon(
                item.hasToolError
                    ? Icons.error_outline_rounded
                    : Icons.check_rounded,
                size: 16,
                color: color,
              ),
      ),
    );
  }

  Widget _buildProcessStatePill(ProcessItem item) {
    final label = item.hasToolError
        ? _label(en: 'Issue', zh: '需处理')
        : item.hasRunningTool || !item.isFinished
            ? _label(en: 'Running', zh: '执行中')
            : _label(en: 'Done', zh: '完成');
    final color = item.hasToolError
        ? const Color(0xFFEF4444)
        : item.hasRunningTool || !item.isFinished
            ? AppColors.primary
            : const Color(0xFF10B981);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }

  String _processTitle(ProcessItem item) {
    final toolCount = item.toolCalls.length;
    if (toolCount == 0) {
      return item.isFinished
          ? _label(en: 'Reasoning complete', zh: '思考完成')
          : _label(en: 'Thinking through request', zh: '正在理解需求');
    }
    if (item.hasToolError) {
      return _label(en: 'Action needs attention', zh: '有动作需要处理');
    }
    if (item.hasRunningTool || !item.isFinished) {
      return _label(
        en: 'Working through ${_pluralizeAction(toolCount)}',
        zh: '正在执行 $toolCount 个动作',
      );
    }
    return _label(
      en: 'Completed ${_pluralizeAction(toolCount)}',
      zh: '已完成 $toolCount 个动作',
    );
  }

  String _processSubtitle(ProcessItem item) {
    final toolCounts = _toolCounts(item.toolCalls);
    if (toolCounts.isEmpty) {
      return item.isFinished
          ? _label(en: 'Internal reasoning finished', zh: '内部推理已完成')
          : _label(en: 'Planning next step', zh: '正在规划下一步');
    }
    return toolCounts.entries
        .take(4)
        .map((entry) => '${_toolDisplayName(entry.key)} x${entry.value}')
        .join(' · ');
  }

  String _pluralizeAction(int count) =>
      count == 1 ? '1 action' : '$count actions';

  Widget _buildToolSummaryChips(ProcessItem item) {
    final entries = _toolCounts(item.toolCalls).entries.toList();
    final visibleEntries = entries.take(4).toList();
    final hiddenCount =
        entries.skip(4).fold<int>(0, (sum, entry) => sum + entry.value);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final entry in visibleEntries)
          _buildToolChip(
            icon: _toolIcon(entry.key),
            label: entry.value == 1
                ? _toolDisplayName(entry.key)
                : '${_toolDisplayName(entry.key)} ${entry.value}',
          ),
        if (hiddenCount > 0)
          _buildToolChip(
            icon: Icons.more_horiz_rounded,
            label: '+$hiddenCount',
          ),
      ],
    );
  }

  Widget _buildToolChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolTraceList(List<ToolCallItem> tools) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFCFE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6EAF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              _label(en: 'Tool activity', zh: '工具活动'),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          for (var index = 0; index < tools.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
            _buildToolCallItem(tools[index]),
          ],
        ],
      ),
    );
  }

  Map<String, int> _toolCounts(List<ToolCallItem> tools) {
    final counts = <String, int>{};
    for (final tool in tools) {
      counts[tool.toolName] = (counts[tool.toolName] ?? 0) + 1;
    }
    return counts;
  }

  IconData _toolIcon(String toolName) {
    switch (toolName.toLowerCase()) {
      case 'grep':
        return Icons.search_rounded;
      case 'glob':
        return Icons.travel_explore_rounded;
      case 'read':
      case 'batchread':
        return Icons.article_outlined;
      case 'write':
        return Icons.note_add_outlined;
      case 'edit':
        return Icons.edit_note_rounded;
      case 'ls':
        return Icons.folder_open_outlined;
      case 'move':
        return Icons.drive_file_move_outline;
      case 'remove':
        return Icons.delete_outline_rounded;
      case 'submit_record':
        return Icons.bookmark_add_outlined;
      case 'create_dynamic_timeline_card':
      case 'update_dynamic_timeline_card':
        return Icons.auto_awesome_mosaic_outlined;
      case 'recommend_dynamic_timeline_design_patterns':
      case 'get_dynamic_timeline_design_pattern':
      case 'list_dynamic_timeline_design_patterns':
        return Icons.palette_outlined;
      default:
        return Icons.extension_outlined;
    }
  }

  String _toolDisplayName(String toolName) {
    switch (toolName.toLowerCase()) {
      case 'grep':
        return _label(en: 'Search', zh: '搜索');
      case 'glob':
        return _label(en: 'Find files', zh: '找文件');
      case 'read':
        return _label(en: 'Read', zh: '读取');
      case 'batchread':
        return _label(en: 'Read batch', zh: '批量读取');
      case 'write':
        return _label(en: 'Write', zh: '写入');
      case 'edit':
        return _label(en: 'Edit', zh: '编辑');
      case 'ls':
        return _label(en: 'List', zh: '列表');
      case 'move':
        return _label(en: 'Move', zh: '移动');
      case 'remove':
        return _label(en: 'Delete', zh: '删除');
      case 'submit_record':
        return _label(en: 'Record', zh: '记录');
      case 'create_dynamic_timeline_card':
        return _label(en: 'Create UI', zh: '生成 UI');
      case 'update_dynamic_timeline_card':
        return _label(en: 'Update UI', zh: '更新 UI');
      case 'recommend_dynamic_timeline_design_patterns':
        return _label(en: 'Find styles', zh: '找样式');
      case 'get_dynamic_timeline_design_pattern':
        return _label(en: 'Read style', zh: '读样式');
      case 'list_dynamic_timeline_design_patterns':
        return _label(en: 'Style library', zh: '样式库');
      case 'save_timeline_card':
        return _label(en: 'Save card', zh: '保存卡片');
      case 'create_calendar_event':
        return _label(en: 'Create event', zh: '创建日历事件');
      case 'create_reminder':
        return _label(en: 'Create reminder', zh: '创建提醒');
      case 'cancel_action':
        return _label(en: 'Cancel reminder/event', zh: '取消提醒/日程');
      case 'retry_failed_timeline_card':
        return _label(en: 'Retry card', zh: '重试卡片');
      case 'update_timeline_card_insight':
        return _label(en: 'Update insight', zh: '更新洞察');
      case 'save_knowledge_insight_cards':
        return _label(en: 'Save insights', zh: '保存洞察卡片');
      case 'delete_knowledge_insight_card':
        return _label(en: 'Delete insight card', zh: '删除洞察卡片');
      case 'delete_knowledge_insight_tags':
        return _label(en: 'Delete insight tags', zh: '删除洞察标签');
      default:
        return toolName;
    }
  }

  String _toolStatusLabel(ToolCallItem item) {
    if (item.isRunning) return _label(en: 'Running', zh: '执行中');
    if (item.isError) return _label(en: 'Failed', zh: '失败');
    final duration = item.duration;
    if (duration == null) return _label(en: 'Done', zh: '完成');
    final milliseconds = duration.inMilliseconds;
    if (milliseconds < 1000) return '${milliseconds}ms';
    return '${(milliseconds / 1000).toStringAsFixed(1)}s';
  }

  bool get _isZhLocale =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh';

  String _label({required String en, required String zh}) {
    return _isZhLocale ? zh : en;
  }

  String _compactPreview(String value, {int maxLength = 96}) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxLength) return compact;
    return '${compact.substring(0, maxLength)}...';
  }

  Widget _buildThinkingItem(ThinkingItem item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology, size: 12, color: Color(0xFFCBD5E1)),
              const SizedBox(width: 6),
              Text(
                _label(en: 'Thinking...', zh: '思考中...'),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          MarkdownBody(
            data: item.text,
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolCallItem(ToolCallItem item) {
    final statusColor = item.isError
        ? const Color(0xFFEF4444)
        : item.isRunning
            ? AppColors.primary
            : const Color(0xFF10B981);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              item.isExpanded = !item.isExpanded;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _toolIcon(item.toolName),
                    size: 15,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _toolDisplayName(item.toolName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF334155),
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _compactPreview(item.args),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textTertiary,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _toolStatusLabel(item),
                  style: TextStyle(
                    fontSize: 10,
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  item.isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (item.isExpanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(en: 'Arguments', zh: '参数'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  item.args,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF334155),
                    height: 1.35,
                  ),
                ),
                if (item.result != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _label(en: 'Result', zh: '结果'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    item.result!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Color(0xFF334155),
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
} // End of _AgentChatDialogState

/// A minimal copy icon shown below AI messages.
/// Only displays a small icon that transitions to a checkmark on success.
class _CopyMessageButton extends StatefulWidget {
  final String text;
  final VoidCallback? onCopied;

  const _CopyMessageButton({required this.text, this.onCopied});

  @override
  State<_CopyMessageButton> createState() => _CopyMessageButtonState();
}

class _CopyMessageButtonState extends State<_CopyMessageButton> {
  bool _copied = false;

  Future<void> _handleCopy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    widget.onCopied?.call();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleCopy,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Icon(
            _copied ? Icons.check_rounded : Icons.copy_outlined,
            key: ValueKey(_copied),
            size: 18,
            color: _copied ? AppColors.success : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}
