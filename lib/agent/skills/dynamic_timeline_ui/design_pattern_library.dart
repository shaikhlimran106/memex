import 'dart:convert';

class DynamicTimelineDesignPattern {
  final String id;
  final String name;
  final String intent;
  final String visualDirection;
  final List<String> matchSignals;
  final List<String> designRules;
  final List<String> dataShape;
  final String avoidWhen;
  final String htmlExample;

  const DynamicTimelineDesignPattern({
    required this.id,
    required this.name,
    required this.intent,
    required this.visualDirection,
    required this.matchSignals,
    required this.designRules,
    required this.dataShape,
    required this.avoidWhen,
    required this.htmlExample,
  });

  Map<String, dynamic> toJson({bool includeHtmlExample = false}) {
    return {
      'id': id,
      'name': name,
      'intent': intent,
      'visual_direction': visualDirection,
      'match_signals': matchSignals,
      'design_rules': designRules,
      'data_shape': dataShape,
      'avoid_when': avoidWhen,
      if (includeHtmlExample) 'html_example': htmlExample,
    };
  }
}

class DynamicTimelineDesignPatternMatch {
  final DynamicTimelineDesignPattern pattern;
  final int score;
  final List<String> reasons;

  const DynamicTimelineDesignPatternMatch({
    required this.pattern,
    required this.score,
    required this.reasons,
  });

  Map<String, dynamic> toJson({bool includeHtmlExample = false}) {
    return {
      'score': score,
      'reasons': reasons,
      ...pattern.toJson(includeHtmlExample: includeHtmlExample),
    };
  }
}

class DynamicTimelineDesignPatternLibrary {
  static const List<DynamicTimelineDesignPattern> patterns = [
    DynamicTimelineDesignPattern(
      id: 'visual_memory_editorial',
      name: 'Visual Memory Editorial',
      intent:
          'Turn photos, screenshots, visual records, or image-heavy moments into a premium editorial memory card.',
      visualDirection:
          'Large visual lead, quiet typography, one clear AI observation, restrained action rail.',
      matchSignals: [
        'photo',
        'image',
        'screenshot',
        'visual',
        'memory',
        'travel',
        'moment',
        'gallery',
        'picture',
      ],
      designRules: [
        'Let the strongest visual own the top half of the card.',
        'Use one short headline and one useful observation, not a paragraph.',
        'Keep metadata small and secondary.',
        'Use soft contrast instead of heavy borders.',
      ],
      dataShape: [
        'title',
        'time_or_place',
        'image_count',
        'primary_observation',
        'optional_next_step',
      ],
      avoidWhen:
          'Avoid for dense metrics, multi-step tasks, or text-only decisions.',
      htmlExample: r'''
<section class="memex-card visual-memory">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#111827}
    .visual-memory{overflow:hidden;border-radius:28px;background:#fbfaf7;border:1px solid rgba(17,24,39,.08);box-shadow:0 18px 46px rgba(15,23,42,.10)}
    .visual-memory .hero{height:210px;background:linear-gradient(135deg,#172033 0%,#405164 38%,#c9b79e 100%);position:relative}
    .visual-memory .hero:after{content:"";position:absolute;inset:0;background:radial-gradient(circle at 78% 18%,rgba(255,255,255,.45),transparent 23%),linear-gradient(180deg,transparent 35%,rgba(0,0,0,.34))}
    .visual-memory .count{position:absolute;left:18px;bottom:18px;padding:8px 11px;border-radius:999px;background:rgba(255,255,255,.82);backdrop-filter:blur(14px);font-size:12px;font-weight:700;letter-spacing:.02em}
    .visual-memory .body{padding:20px 20px 22px}
    .visual-memory .eyebrow{font-size:11px;font-weight:800;letter-spacing:.16em;text-transform:uppercase;color:#8a6f48}
    .visual-memory h2{margin:8px 0 12px;font-size:27px;line-height:1.02;letter-spacing:0;font-weight:850}
    .visual-memory p{margin:0;color:#4b5563;font-size:15px;line-height:1.58}
    .visual-memory .insight{margin-top:18px;padding:14px 15px;border-radius:18px;background:#fff;border:1px solid rgba(17,24,39,.07);display:flex;gap:12px;align-items:flex-start}
    .visual-memory .dot{width:9px;height:9px;margin-top:7px;border-radius:999px;background:#111827;box-shadow:0 0 0 5px rgba(17,24,39,.08)}
    .visual-memory .insight strong{display:block;font-size:13px;margin-bottom:3px}
    .visual-memory .insight span{display:block;font-size:13px;color:#64748b;line-height:1.45}
  </style>
  <div class="hero"><div class="count">2 visuals captured</div></div>
  <div class="body">
    <div class="eyebrow">Today / Visual memory</div>
    <h2>Small signals from a busy afternoon</h2>
    <p>The images read like a work moment worth saving: a place, a screen, and a decision still forming.</p>
    <div class="insight"><div class="dot"></div><div><strong>AI observation</strong><span>Archive this as a visual note, then connect it to the current project thread.</span></div></div>
  </div>
</section>
''',
    ),
    DynamicTimelineDesignPattern(
      id: 'work_progress_command',
      name: 'Work Progress Command',
      intent:
          'Summarize project movement, work execution, task progress, or a plan that needs next actions.',
      visualDirection:
          'Dense but elegant command-center layout with status, steps, and a single next move.',
      matchSignals: [
        'project',
        'work',
        'task',
        'progress',
        'roadmap',
        'meeting',
        'plan',
        'next step',
        'todo',
      ],
      designRules: [
        'Make status visible in the first glance.',
        'Show at most three steps or checkpoints.',
        'Use one action recommendation, not a menu.',
        'Prefer sober contrast and compact spacing.',
      ],
      dataShape: [
        'project_name',
        'status',
        'completed_items',
        'blocked_items',
        'recommended_next_step',
      ],
      avoidWhen: 'Avoid for emotional diary entries or image-first memories.',
      htmlExample: r'''
<section class="memex-card work-command">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#0f172a}
    .work-command{border-radius:24px;background:#0f172a;color:#f8fafc;padding:20px;border:1px solid rgba(255,255,255,.10);box-shadow:0 22px 48px rgba(2,6,23,.24)}
    .work-command .top{display:flex;justify-content:space-between;gap:14px;align-items:flex-start}
    .work-command .label{font-size:11px;font-weight:800;letter-spacing:.15em;text-transform:uppercase;color:#93c5fd}
    .work-command h2{margin:8px 0 0;font-size:24px;line-height:1.12;font-weight:850;letter-spacing:0}
    .work-command .status{padding:8px 10px;border-radius:999px;background:rgba(34,197,94,.14);color:#bbf7d0;font-size:12px;font-weight:800;white-space:nowrap}
    .work-command .grid{margin-top:20px;display:grid;grid-template-columns:1fr;gap:10px}
    .work-command .row{display:flex;gap:12px;padding:13px;border-radius:17px;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.08)}
    .work-command .index{width:26px;height:26px;border-radius:9px;background:#f8fafc;color:#0f172a;display:grid;place-items:center;font-size:12px;font-weight:900;flex:0 0 auto}
    .work-command strong{display:block;font-size:14px;margin-bottom:3px}
    .work-command span{display:block;color:#cbd5e1;font-size:13px;line-height:1.45}
    .work-command .next{margin-top:14px;padding:15px;border-radius:18px;background:#f8fafc;color:#0f172a}
    .work-command .next b{font-size:13px;text-transform:uppercase;letter-spacing:.1em;color:#64748b}
    .work-command .next p{margin:6px 0 0;font-size:15px;line-height:1.45;font-weight:720}
  </style>
  <div class="top"><div><div class="label">Project pulse</div><h2>Roadmap review is moving again</h2></div><div class="status">On track</div></div>
  <div class="grid">
    <div class="row"><div class="index">1</div><div><strong>Archived</strong><span>The key deck and notes are now tied to this project thread.</span></div></div>
    <div class="row"><div class="index">2</div><div><strong>Needs edit</strong><span>Slide 7 has the highest leverage for simplifying the story.</span></div></div>
  </div>
  <div class="next"><b>Recommended next move</b><p>Compress the data chart and turn the follow-up into one concrete owner-task.</p></div>
</section>
''',
    ),
    DynamicTimelineDesignPattern(
      id: 'personal_review_magazine',
      name: 'Personal Review Magazine',
      intent:
          'Render a diary-like reflection, daily review, life note, or emotional personal recap as a polished magazine card.',
      visualDirection:
          'Editorial typography, warm paper feel, quiet emotional summary, sparse details.',
      matchSignals: [
        'diary',
        'journal',
        'review',
        'reflection',
        'life',
        'emotion',
        'mood',
        'memory',
        'recap',
      ],
      designRules: [
        'Use one expressive headline, then keep the body grounded.',
        'Avoid dashboard styling unless there are real metrics.',
        'Let whitespace carry the premium feel.',
        'Use warm neutrals with one unexpected accent.',
      ],
      dataShape: [
        'headline',
        'emotional_tone',
        'summary',
        'notable_detail',
        'gentle_prompt',
      ],
      avoidWhen:
          'Avoid for execution logs, system changes, or dense quantitative data.',
      htmlExample: r'''
<section class="memex-card review-mag">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#1f2937}
    .review-mag{border-radius:30px;padding:24px;background:linear-gradient(145deg,#fffaf0 0%,#f8fafc 58%,#eef6f3 100%);border:1px solid rgba(31,41,55,.08);box-shadow:0 18px 40px rgba(31,41,55,.10)}
    .review-mag .mast{display:flex;justify-content:space-between;align-items:flex-start;gap:16px}
    .review-mag .kicker{font-size:11px;font-weight:900;letter-spacing:.18em;text-transform:uppercase;color:#0f766e}
    .review-mag .date{font-size:12px;color:#9ca3af;font-weight:700}
    .review-mag h2{margin:18px 0 14px;font-size:32px;line-height:.98;font-weight:900;letter-spacing:0;max-width:11ch}
    .review-mag .summary{font-size:15px;line-height:1.62;color:#4b5563;margin:0}
    .review-mag .quote{margin-top:20px;border-left:3px solid #111827;padding-left:14px;color:#111827;font-size:16px;line-height:1.5;font-weight:720}
    .review-mag .footer{margin-top:22px;display:flex;justify-content:space-between;gap:12px;color:#6b7280;font-size:12px;font-weight:700}
    .review-mag .pill{padding:7px 10px;border-radius:999px;background:rgba(15,118,110,.10);color:#0f766e}
  </style>
  <div class="mast"><div class="kicker">Personal review</div><div class="date">20:30</div></div>
  <h2>A quieter signal under the day</h2>
  <p class="summary">The important part is not the amount recorded, but the pattern: attention kept returning to the same unresolved thread.</p>
  <div class="quote">Save this as a prompt for tomorrow, not a task for tonight.</div>
  <div class="footer"><span>Memory tone</span><span class="pill">reflective</span></div>
</section>
''',
    ),
    DynamicTimelineDesignPattern(
      id: 'metric_signal_dashboard',
      name: 'Metric Signal Dashboard',
      intent:
          'Display health, finance, habit, productivity, or measurable status as a compact premium dashboard.',
      visualDirection:
          'Precise metrics, calm chart-like rhythm, one interpretation layer.',
      matchSignals: [
        'metric',
        'data',
        'health',
        'finance',
        'money',
        'habit',
        'score',
        'trend',
        'dashboard',
        'stats',
      ],
      designRules: [
        'Use numbers only when the input supports them.',
        'Show the interpretation beside the metric, not below a long paragraph.',
        'Use micro charts as visual hierarchy, not decoration.',
        'Keep labels explicit and compact.',
      ],
      dataShape: [
        'primary_metric',
        'secondary_metrics',
        'trend',
        'interpretation',
        'risk_or_next_step',
      ],
      avoidWhen:
          'Avoid when the source is qualitative and has no measurable signal.',
      htmlExample: r'''
<section class="memex-card metric-dashboard">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#102027}
    .metric-dashboard{border-radius:26px;background:#f7fbff;padding:19px;border:1px solid rgba(16,32,39,.08);box-shadow:0 18px 44px rgba(16,32,39,.10)}
    .metric-dashboard .header{display:flex;justify-content:space-between;align-items:center}
    .metric-dashboard .title{font-size:13px;font-weight:850;color:#38546b;letter-spacing:.08em;text-transform:uppercase}
    .metric-dashboard .trend{font-size:12px;font-weight:850;color:#0f766e;background:rgba(20,184,166,.12);padding:7px 10px;border-radius:999px}
    .metric-dashboard .main{margin-top:18px;display:grid;grid-template-columns:1.1fr .9fr;gap:14px;align-items:end}
    .metric-dashboard .number{font-size:46px;line-height:.9;font-weight:900;letter-spacing:0;color:#0f172a}
    .metric-dashboard .label{margin-top:8px;color:#64748b;font-size:13px;font-weight:700}
    .metric-dashboard .bars{height:86px;display:flex;gap:7px;align-items:end;padding:10px;border-radius:18px;background:#fff;border:1px solid rgba(16,32,39,.06)}
    .metric-dashboard .bars i{display:block;flex:1;border-radius:999px;background:linear-gradient(180deg,#38bdf8,#0f766e)}
    .metric-dashboard .bars i:nth-child(1){height:32%}.metric-dashboard .bars i:nth-child(2){height:64%}.metric-dashboard .bars i:nth-child(3){height:48%}.metric-dashboard .bars i:nth-child(4){height:78%}.metric-dashboard .bars i:nth-child(5){height:58%}
    .metric-dashboard .insight{margin-top:15px;padding:14px;border-radius:18px;background:#102027;color:#e5f4ff;font-size:14px;line-height:1.48}
  </style>
  <div class="header"><div class="title">Signal dashboard</div><div class="trend">stable</div></div>
  <div class="main"><div><div class="number">72</div><div class="label">current signal score</div></div><div class="bars"><i></i><i></i><i></i><i></i><i></i></div></div>
  <div class="insight">The trend is usable, but not strong enough to automate. Keep it as a watch signal.</div>
</section>
''',
    ),
    DynamicTimelineDesignPattern(
      id: 'decision_studio',
      name: 'Decision Studio',
      intent:
          'Help the user compare options, make a choice, or preserve a reasoning snapshot.',
      visualDirection:
          'Two-column comparison, clear recommendation, low-noise decision language.',
      matchSignals: [
        'decide',
        'choice',
        'compare',
        'option',
        'pros',
        'cons',
        'tradeoff',
        'recommend',
        'decision',
      ],
      designRules: [
        'Make the recommended direction visible, but do not hide tradeoffs.',
        'Use parallel labels so the comparison is scannable.',
        'Keep each option to one or two lines.',
        'End with the next question if confidence is low.',
      ],
      dataShape: [
        'decision_question',
        'option_a',
        'option_b',
        'recommendation',
        'confidence',
      ],
      avoidWhen:
          'Avoid for pure records where the user is not making a choice.',
      htmlExample: r'''
<section class="memex-card decision-studio">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#111827}
    .decision-studio{border-radius:26px;background:#ffffff;padding:19px;border:1px solid rgba(17,24,39,.08);box-shadow:0 18px 42px rgba(17,24,39,.11)}
    .decision-studio .kicker{font-size:11px;font-weight:900;letter-spacing:.16em;text-transform:uppercase;color:#7c3aed}
    .decision-studio h2{margin:9px 0 16px;font-size:25px;line-height:1.1;letter-spacing:0;font-weight:900}
    .decision-studio .options{display:grid;grid-template-columns:1fr 1fr;gap:10px}
    .decision-studio .option{border-radius:18px;padding:14px;background:#f8fafc;border:1px solid rgba(17,24,39,.06)}
    .decision-studio .option b{display:block;font-size:12px;color:#64748b;text-transform:uppercase;letter-spacing:.1em;margin-bottom:8px}
    .decision-studio .option span{display:block;font-size:14px;line-height:1.45;font-weight:680}
    .decision-studio .pick{margin-top:13px;border-radius:19px;padding:15px;background:#111827;color:#fff}
    .decision-studio .pick b{display:block;font-size:12px;color:#c4b5fd;letter-spacing:.1em;text-transform:uppercase;margin-bottom:5px}
    .decision-studio .pick p{margin:0;font-size:15px;line-height:1.48;font-weight:720}
  </style>
  <div class="kicker">Decision studio</div>
  <h2>Which direction has the better next step?</h2>
  <div class="options"><div class="option"><b>Option A</b><span>Fast to ship, but keeps the same UX ambiguity.</span></div><div class="option"><b>Option B</b><span>Slower today, clearer foundation for future use.</span></div></div>
  <div class="pick"><b>Recommendation</b><p>Choose B if the user will revisit this flow repeatedly.</p></div>
</section>
''',
    ),
    DynamicTimelineDesignPattern(
      id: 'system_action_receipt',
      name: 'System Action Receipt',
      intent:
          'Show what an agent changed, generated, archived, scheduled, or prepared inside Memex.',
      visualDirection:
          'Trust-building receipt with action, affected surface, permission note, and rollback hint.',
      matchSignals: [
        'action',
        'changed',
        'updated',
        'created',
        'scheduled',
        'archived',
        'configured',
        'agent',
        'system',
      ],
      designRules: [
        'State exactly what happened.',
        'Expose affected areas without noisy logs.',
        'Show whether user approval was required.',
        'Include rollback or follow-up only when real.',
      ],
      dataShape: [
        'action_name',
        'affected_area',
        'permission_state',
        'result',
        'rollback_hint',
      ],
      avoidWhen:
          'Avoid for reflective content or media memories with no system action.',
      htmlExample: r'''
<section class="memex-card action-receipt">
  <style>
    .memex-card{box-sizing:border-box;width:100%;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Inter",sans-serif;color:#111827}
    .action-receipt{border-radius:24px;background:#f9fafb;padding:18px;border:1px solid rgba(17,24,39,.08);box-shadow:0 14px 34px rgba(17,24,39,.09)}
    .action-receipt .head{display:flex;gap:12px;align-items:center}
    .action-receipt .mark{width:42px;height:42px;border-radius:15px;background:#111827;color:#fff;display:grid;place-items:center;font-size:20px;font-weight:900}
    .action-receipt .meta{font-size:11px;font-weight:900;letter-spacing:.15em;text-transform:uppercase;color:#64748b}
    .action-receipt h2{margin:3px 0 0;font-size:21px;line-height:1.15;font-weight:850;letter-spacing:0}
    .action-receipt .panel{margin-top:15px;background:#fff;border:1px solid rgba(17,24,39,.07);border-radius:18px;overflow:hidden}
    .action-receipt .row{display:flex;justify-content:space-between;gap:12px;padding:13px 14px;border-bottom:1px solid rgba(17,24,39,.06);font-size:13px}
    .action-receipt .row:last-child{border-bottom:0}
    .action-receipt .row span{color:#64748b;font-weight:700}
    .action-receipt .row b{text-align:right;font-weight:800}
    .action-receipt .note{margin-top:13px;font-size:13px;line-height:1.46;color:#475569}
  </style>
  <div class="head"><div class="mark">OK</div><div><div class="meta">Agent receipt</div><h2>Timeline UI card created</h2></div></div>
  <div class="panel"><div class="row"><span>Affected surface</span><b>Timeline</b></div><div class="row"><span>Permission</span><b>Auto allowed</b></div><div class="row"><span>Status</span><b>Completed</b></div></div>
  <div class="note">The generated card is saved as a normal Memex timeline card and can be revised by asking the agent.</div>
</section>
''',
    ),
  ];

  static DynamicTimelineDesignPattern? findById(String id) {
    final cleanId = id.trim();
    for (final pattern in patterns) {
      if (pattern.id == cleanId) return pattern;
    }
    return null;
  }

  static DynamicTimelineDesignPattern requireById(String id) {
    final pattern = findById(id);
    if (pattern == null) {
      throw ArgumentError(
        'Unknown design_pattern_id "$id". Available patterns: ${patterns.map((p) => p.id).join(', ')}.',
      );
    }
    return pattern;
  }

  static List<DynamicTimelineDesignPatternMatch> recommend({
    required String intent,
    String? contentSummary,
    String? constraints,
    int limit = 3,
  }) {
    final query = [
      intent,
      contentSummary ?? '',
      constraints ?? '',
    ].join(' ').toLowerCase();

    final matches = patterns.map((pattern) {
      var score = 0;
      final reasons = <String>[];

      for (final signal in pattern.matchSignals) {
        if (query.contains(signal.toLowerCase())) {
          score += 4;
          reasons.add('matched signal "$signal"');
        }
      }

      for (final token in pattern.id.split('_')) {
        if (query.contains(token)) {
          score += 1;
        }
      }

      if (query.contains('premium') ||
          query.contains('polished') ||
          query.contains('designer')) {
        score += 1;
      }

      if (score == 0) {
        score = 1;
        reasons.add('fallback candidate');
      }

      return DynamicTimelineDesignPatternMatch(
        pattern: pattern,
        score: score,
        reasons: reasons.take(4).toList(),
      );
    }).toList()
      ..sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        if (scoreCompare != 0) return scoreCompare;
        return a.pattern.id.compareTo(b.pattern.id);
      });

    final safeLimit = limit.clamp(1, patterns.length).toInt();
    return matches.take(safeLimit).toList();
  }

  static String catalogJson() {
    return const JsonEncoder.withIndent('  ').convert(
      patterns.map((pattern) => pattern.toJson()).toList(),
    );
  }

  static String patternJson(String id) {
    return const JsonEncoder.withIndent('  ').convert(
      requireById(id).toJson(includeHtmlExample: true),
    );
  }

  static String recommendationJson({
    required String intent,
    String? contentSummary,
    String? constraints,
    int limit = 3,
  }) {
    return const JsonEncoder.withIndent('  ').convert(
      recommend(
        intent: intent,
        contentSummary: contentSummary,
        constraints: constraints,
        limit: limit,
      ).map((match) => match.toJson()).toList(),
    );
  }
}
