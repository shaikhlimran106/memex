import 'dart:convert';
import 'dart:io';

import 'package:memex/data/repositories/submit_input.dart'
    as submit_input_endpoint;
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/system_action_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

final _logger = getLogger('AgenticSurfaceService');

bool looksLikeAgenticSurfaceIntent(String input) {
  final text = input.trim().toLowerCase();
  if (text.isEmpty) return false;

  final uiTerms = [
    'ui',
    'html',
    'webview',
    'web view',
    'surface',
    '页面',
    '界面',
    '样式',
    '布局',
    '按钮',
    '面板',
    '工作台',
    'dashboard',
    '卡片样式',
    '改成',
    '做一个',
    '生成一个',
    '护眼',
    '紧凑',
  ];

  final actionTerms = [
    '改',
    '做',
    '生成',
    '设计',
    '调整',
    '换',
    '定制',
    'custom',
    'build',
    'create',
  ];

  final hasUiTerm = uiTerms.any(text.contains);
  final hasActionTerm = actionTerms.any(text.contains);
  return hasUiTerm && hasActionTerm;
}

class AgenticSurfaceDraft {
  const AgenticSurfaceDraft({
    required this.id,
    required this.title,
    required this.intent,
    required this.html,
    required this.summary,
    required this.filePath,
  });

  final String id;
  final String title;
  final String intent;
  final String html;
  final String summary;
  final String filePath;
}

class AgenticSurfaceService {
  static final AgenticSurfaceService instance = AgenticSurfaceService._();
  AgenticSurfaceService._();

  static const String defaultSurfaceId = 'super_agent_surface';

  FileSystemService get _fileSystem => FileSystemService.instance;

  Future<AgenticSurfaceDraft> createOrUpdateSurface({
    required String intent,
    String surfaceId = defaultSurfaceId,
  }) async {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw StateError('User not logged in.');
    }

    final html = renderHtmlForIntent(intent);
    final title = titleForIntent(intent);
    final summary = summaryForIntent(intent);
    final surfaceDir = Directory(
      p.join(_fileSystem.getUserSettingsPath(userId), 'AgenticSurfaces'),
    );
    await surfaceDir.create(recursive: true);

    final htmlFile = File(p.join(surfaceDir.path, '$surfaceId.html'));
    await htmlFile.writeAsString(html);

    final manifestFile = File(p.join(surfaceDir.path, '$surfaceId.json'));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'id': surfaceId,
        'title': title,
        'intent': intent,
        'summary': summary,
        'html_path': _fileSystem.toRelativePath(htmlFile.path),
        'updated_at': DateTime.now().toIso8601String(),
        'allowed_capabilities': [
          'submit_record',
          'create_reminder',
          'get_context',
          'update_surface',
        ],
      }),
    );

    _logger.info('Agentic surface updated: ${htmlFile.path}');
    return AgenticSurfaceDraft(
      id: surfaceId,
      title: title,
      intent: intent,
      html: html,
      summary: summary,
      filePath: htmlFile.path,
    );
  }

  Future<Map<String, dynamic>> callCapability({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    switch (name) {
      case 'submit_record':
        return _submitRecord(args);
      case 'create_reminder':
        return _createReminder(args);
      case 'get_context':
        return {
          'ok': true,
          'now': DateTime.now().toIso8601String(),
          'capabilities': [
            'submit_record',
            'create_reminder',
            'get_context',
            'update_surface',
          ],
        };
      default:
        throw UnsupportedError('Capability "$name" is not available.');
    }
  }

  Future<Map<String, dynamic>> _submitRecord(Map<String, dynamic> args) async {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw StateError('User not logged in.');
    }

    final content = args['content']?.toString().trim() ?? '';
    if (content.isEmpty) {
      throw ArgumentError('content is required.');
    }

    final response = await submit_input_endpoint.submitInput(userId, [
      {'type': 'text', 'text': content},
    ]);
    return {
      'ok': true,
      'message': '记录已提交，卡片和 PKM 会继续异步处理。',
      'fact_id': response['fact_id'],
    };
  }

  Future<Map<String, dynamic>> _createReminder(
    Map<String, dynamic> args,
  ) async {
    final title = args['title']?.toString().trim();
    if (title == null || title.isEmpty) {
      throw ArgumentError('title is required.');
    }
    final dueDate = args['time']?.toString().trim().isNotEmpty == true
        ? args['time'].toString().trim()
        : args['due_date']?.toString().trim();
    final actionId = const Uuid().v4();
    await SystemActionService.instance.createAction(
      id: actionId,
      type: 'reminder',
      data: {
        'title': title,
        if (dueDate != null && dueDate.isNotEmpty) 'due_date': dueDate,
        'notes': 'Created from Agentic Surface prototype.',
      },
    );
    return {
      'ok': true,
      'message': '已创建一个待处理提醒动作。',
      'action_id': actionId,
    };
  }

  static String titleForIntent(String intent) {
    final text = intent.toLowerCase();
    if (text.contains('复盘') || text.contains('review')) return '今日复盘';
    if (text.contains('工作') || text.contains('dashboard')) return 'Memex 工作台';
    if (text.contains('记录') || text.contains('日记')) return '记录面板';
    return 'Agentic Surface';
  }

  static String summaryForIntent(String intent) {
    final theme = _themeForIntent(intent);
    final density = _compactForIntent(intent) ? '紧凑' : '舒展';
    return '${theme.label} · $density · HTML Surface';
  }

  static String renderHtmlForIntent(String intent) {
    final theme = _themeForIntent(intent);
    final compact = _compactForIntent(intent);
    final title = titleForIntent(intent);
    final gap = compact ? 10 : 16;
    final padding = compact ? 18 : 24;
    final radius = compact ? 18 : 26;
    final bodySize = compact ? 14 : 16;
    final escapedIntent = const HtmlEscape().convert(intent.trim());

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    :root {
      color-scheme: light;
      --bg: ${theme.bg};
      --panel: ${theme.panel};
      --ink: ${theme.ink};
      --muted: ${theme.muted};
      --accent: ${theme.accent};
      --accent-soft: ${theme.accentSoft};
      --line: ${theme.line};
      --shadow: ${theme.shadow};
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    .surface {
      min-height: 100vh;
      padding: ${padding}px;
      display: flex;
      flex-direction: column;
      gap: ${gap}px;
    }
    .hero {
      padding: ${padding}px;
      border: 1px solid var(--line);
      border-radius: ${radius}px;
      background: var(--panel);
      box-shadow: 0 18px 48px var(--shadow);
    }
    .eyebrow {
      margin: 0 0 8px;
      color: var(--accent);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0;
      text-transform: uppercase;
    }
    h1 {
      margin: 0;
      font-size: ${compact ? 32 : 38}px;
      line-height: 1.04;
      letter-spacing: 0;
    }
    .sub {
      margin: 12px 0 0;
      color: var(--muted);
      font-size: ${bodySize}px;
      line-height: 1.55;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: ${gap}px;
    }
    .tile, .composer {
      border: 1px solid var(--line);
      background: var(--panel);
      border-radius: ${radius - 4}px;
      padding: ${compact ? 14 : 18}px;
    }
    .tile strong {
      display: block;
      font-size: ${bodySize}px;
      margin-bottom: 6px;
    }
    .tile span {
      color: var(--muted);
      font-size: ${compact ? 12 : 13}px;
      line-height: 1.35;
    }
    textarea {
      width: 100%;
      min-height: ${compact ? 78 : 104}px;
      resize: none;
      border: 1px solid var(--line);
      border-radius: ${radius - 8}px;
      background: ${theme.input};
      color: var(--ink);
      padding: 14px;
      font: inherit;
      font-size: ${bodySize}px;
      outline: none;
    }
    .row {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    button {
      border: 0;
      border-radius: 999px;
      padding: ${compact ? '10px 14px' : '12px 18px'};
      background: var(--accent);
      color: white;
      font-size: ${compact ? 13 : 14}px;
      font-weight: 800;
    }
    button.secondary {
      color: var(--accent);
      background: var(--accent-soft);
    }
    .status {
      min-height: 22px;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.45;
      margin-top: 10px;
    }
    @media (max-width: 420px) {
      .grid { grid-template-columns: 1fr; }
      h1 { font-size: ${compact ? 30 : 34}px; }
    }
  </style>
</head>
<body>
  <main class="surface">
    <section class="hero">
      <p class="eyebrow">Memex Surface Prototype</p>
      <h1>$title</h1>
      <p class="sub">这是 Super Agent 根据你的意图生成的 HTML Surface。它不是静态图片，下面的按钮会通过 <code>memex.call(...)</code> 调用 App 里的受控能力。</p>
    </section>

    <section class="grid">
      <div class="tile">
        <strong>当前样式</strong>
        <span>${summaryForIntent(intent)}</span>
      </div>
      <div class="tile">
        <strong>用户意图</strong>
        <span>$escapedIntent</span>
      </div>
    </section>

    <section class="composer">
      <textarea id="recordText" placeholder="写一条记录，或者把今天的想法先放在这里..."></textarea>
      <div class="row">
        <button onclick="submitRecord()">记录到 Memex</button>
        <button class="secondary" onclick="createReviewReminder()">22:30 复盘提醒</button>
        <button class="secondary" onclick="askContext()">读取上下文</button>
      </div>
      <div id="status" class="status">Surface 已就绪。</div>
    </section>
  </main>

  <script>
    function setStatus(text) {
      document.getElementById('status').textContent = text;
    }
    async function submitRecord() {
      const text = document.getElementById('recordText').value.trim() || '从 Agentic Surface 创建的一条测试记录';
      setStatus('正在提交记录...');
      const result = await memex.call('submit_record', { content: text });
      setStatus(result.message || ('记录已提交：' + result.fact_id));
    }
    async function createReviewReminder() {
      setStatus('正在创建提醒动作...');
      const result = await memex.call('create_reminder', {
        title: '晚间复盘',
        time: '22:30'
      });
      setStatus(result.message + ' ID: ' + result.action_id);
    }
    async function askContext() {
      const result = await memex.call('get_context', {});
      setStatus('当前时间：' + result.now + '；能力：' + result.capabilities.join(', '));
    }
  </script>
</body>
</html>
''';
  }

  static bool _compactForIntent(String intent) {
    final text = intent.toLowerCase();
    return text.contains('紧凑') ||
        text.contains('小一点') ||
        text.contains('密') ||
        text.contains('compact');
  }

  static _SurfaceTheme _themeForIntent(String intent) {
    final text = intent.toLowerCase();
    if (text.contains('暗') || text.contains('夜') || text.contains('dark')) {
      return const _SurfaceTheme(
        label: '深色',
        bg: '#0f172a',
        panel: '#111827',
        input: '#0b1220',
        ink: '#f8fafc',
        muted: '#94a3b8',
        accent: '#8b5cf6',
        accentSoft: '#2e245d',
        line: '#243044',
        shadow: 'rgba(0, 0, 0, 0.26)',
      );
    }
    if (text.contains('护眼') || text.contains('绿色') || text.contains('green')) {
      return const _SurfaceTheme(
        label: '护眼',
        bg: '#f3f8ef',
        panel: '#ffffff',
        input: '#f8fbf5',
        ink: '#132015',
        muted: '#667567',
        accent: '#3f8f5f',
        accentSoft: '#e2f1e5',
        line: '#d9e8d5',
        shadow: 'rgba(59, 98, 74, 0.10)',
      );
    }
    if (text.contains('暖') || text.contains('橙') || text.contains('warm')) {
      return const _SurfaceTheme(
        label: '温暖',
        bg: '#fff7ed',
        panel: '#ffffff',
        input: '#fffaf4',
        ink: '#24140c',
        muted: '#806b5d',
        accent: '#d97706',
        accentSoft: '#ffedd5',
        line: '#fed7aa',
        shadow: 'rgba(154, 83, 20, 0.10)',
      );
    }
    return const _SurfaceTheme(
      label: '默认',
      bg: '#f8fafc',
      panel: '#ffffff',
      input: '#f8fafc',
      ink: '#0f172a',
      muted: '#64748b',
      accent: '#5865f2',
      accentSoft: '#eef2ff',
      line: '#e2e8f0',
      shadow: 'rgba(15, 23, 42, 0.08)',
    );
  }
}

class _SurfaceTheme {
  const _SurfaceTheme({
    required this.label,
    required this.bg,
    required this.panel,
    required this.input,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.accentSoft,
    required this.line,
    required this.shadow,
  });

  final String label;
  final String bg;
  final String panel;
  final String input;
  final String ink;
  final String muted;
  final String accent;
  final String accentSoft;
  final String line;
  final String shadow;
}
