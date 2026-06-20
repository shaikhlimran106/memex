import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/ui/core/themes/app_colors.dart';
import 'package:memex/ui/core/widgets/agent_logo_loading.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;

typedef AgentRunTraceContentReader = Future<String> Function();

class AgentRunTraceViewerEntry {
  const AgentRunTraceViewerEntry({
    required this.path,
    required this.title,
    required this.subtitle,
    required this.modified,
    required this.readContent,
  });

  final String path;
  final String title;
  final String subtitle;
  final DateTime modified;
  final AgentRunTraceContentReader readContent;
}

class AgentRunTraceViewerPage extends StatefulWidget {
  const AgentRunTraceViewerPage({
    super.key,
    this.enableTextSelection = true,
    this.traceEntriesForTesting,
    this.traceRootPathForTesting,
    this.userIdForTesting,
  });

  final bool enableTextSelection;
  final List<AgentRunTraceViewerEntry>? traceEntriesForTesting;
  final String? traceRootPathForTesting;
  final String? userIdForTesting;

  @override
  State<AgentRunTraceViewerPage> createState() =>
      _AgentRunTraceViewerPageState();
}

class _AgentRunTraceViewerPageState extends State<AgentRunTraceViewerPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<AgentRunTraceViewerEntry> _traces = const [];
  AgentRunTraceViewerEntry? _selectedTrace;
  String _content = '';
  String _query = '';
  bool _isLoading = true;
  bool _isReading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTraces();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadTraces() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final traceEntriesForTesting = widget.traceEntriesForTesting;
      if (traceEntriesForTesting != null) {
        final traces = [...traceEntriesForTesting]
          ..sort((a, b) => b.modified.compareTo(a.modified));
        setState(() {
          _traces = traces;
          _selectedTrace = traces.isEmpty ? null : traces.first;
          _isLoading = false;
        });

        if (traces.isNotEmpty) {
          await _selectTrace(traces.first);
        }
        return;
      }

      final userId = widget.userIdForTesting ?? await UserStorage.getUserId();
      if (userId == null || userId.isEmpty) {
        setState(() {
          _traces = const [];
          _selectedTrace = null;
          _content = '';
          _error = 'No active user.';
          _isLoading = false;
        });
        return;
      }

      final root = Directory(
        widget.traceRootPathForTesting ??
            p.join(
              FileSystemService.instance.getSystemPath(userId),
              'AgentRuns',
            ),
      );
      final traces = <AgentRunTraceViewerEntry>[];
      if (await root.exists()) {
        traces.addAll(await _listTraceFiles(root));
      }
      traces.sort((a, b) => b.modified.compareTo(a.modified));

      setState(() {
        _traces = traces;
        _selectedTrace = traces.isEmpty ? null : traces.first;
        _isLoading = false;
      });

      if (traces.isNotEmpty) {
        await _selectTrace(traces.first);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<List<AgentRunTraceViewerEntry>> _listTraceFiles(Directory root) async {
    final traces = <AgentRunTraceViewerEntry>[];
    await for (final dateEntity in root.list()) {
      if (dateEntity is! Directory) continue;
      await for (final runEntity in dateEntity.list()) {
        if (runEntity is! Directory) continue;
        final traceFile = File(p.join(runEntity.path, 'trace.md'));
        if (await traceFile.exists()) {
          traces.add(await _entryFromFile(root.path, traceFile));
        }
      }
    }
    return traces;
  }

  Future<void> _selectTrace(AgentRunTraceViewerEntry trace) async {
    setState(() {
      _selectedTrace = trace;
      _isReading = true;
      _error = null;
    });

    try {
      final content = await trace.readContent();
      if (!mounted) return;
      setState(() {
        _content = content;
        _isReading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _content = '';
        _error = e.toString();
        _isReading = false;
      });
    }
  }

  String get _visibleContent {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _content;
    final lines = _content.split('\n');
    return lines.where((line) => line.toLowerCase().contains(query)).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text('Agent Run Traces'),
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.background,
        foregroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadTraces,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: AgentLogoLoading())
          : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null && _traces.isEmpty) {
      return Center(child: Text(_error!));
    }
    if (_traces.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No Agent Run traces yet. Run Super Agent once, then refresh.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 760;
    if (wide) {
      return Row(
        children: [
          SizedBox(width: 320, child: _buildTraceList()),
          const VerticalDivider(width: 1),
          Expanded(child: _buildTraceContent()),
        ],
      );
    }
    return Column(
      children: [
        SizedBox(height: 180, child: _buildTraceList()),
        const Divider(height: 1),
        Expanded(child: _buildTraceContent()),
      ],
    );
  }

  Widget _buildTraceList() {
    return Material(
      color: Colors.white,
      child: ListView.separated(
        itemCount: _traces.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final trace = _traces[index];
          final selected = trace.path == _selectedTrace?.path;
          return ListTile(
            selected: selected,
            selectedTileColor: AppColors.primary.withValues(alpha: 0.08),
            leading: Icon(
              Icons.psychology_alt_outlined,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(
              trace.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              trace.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            onTap: () => _selectTrace(trace),
          );
        },
      ),
    );
  }

  Widget _buildTraceContent() {
    final selected = _selectedTrace;
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selected?.path ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Top',
                    onPressed: () {
                      if (_scrollController.hasClients) {
                        _scrollController.animateTo(
                          0,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    icon: const Icon(Icons.vertical_align_top, size: 20),
                  ),
                ],
              ),
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Filter inside this trace...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isReading
              ? const Center(child: AgentLogoLoading())
              : _buildReadableTraceContent(),
        ),
      ],
    );
  }

  Widget _buildReadableTraceContent() {
    final content = Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        child: Text(
          _visibleContent.isEmpty ? 'No matching lines.' : _visibleContent,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 12,
            height: 1.45,
            color: Color(0xFF222222),
          ),
        ),
      ),
    );

    if (!widget.enableTextSelection) {
      return content;
    }
    return SelectionArea(child: content);
  }

  static Future<AgentRunTraceViewerEntry> _entryFromFile(
    String rootPath,
    File file,
  ) async {
    final stat = await file.stat();
    final relative = p.relative(file.path, from: rootPath);
    final parts = p.split(relative);
    final date = parts.isNotEmpty ? parts.first : 'unknown date';
    final runId = parts.length >= 2 ? parts[1] : p.basename(file.parent.path);

    return AgentRunTraceViewerEntry(
      path: file.path,
      title: date,
      subtitle: runId,
      modified: stat.modified,
      readContent: file.readAsString,
    );
  }
}
