import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/domain/models/card_detail_model.dart';
import 'package:memex/domain/models/card_model.dart';
import 'package:memex/ui/timeline/widgets/timeline_card_detail_screen.dart';

void main() {
  testWidgets('prefers structured card content over raw fact text',
      (tester) async {
    final detail = _detail(
      rawContent: '### 瑶瑶\n这段角色陪伴内容应该只出现在评论区。',
      uiConfigs: const [
        UiConfig(
          templateId: 'article',
          data: {
            'title': '端午的温馨家常晚餐和太顺杨梅',
            'body': '一家人吃了家常晚餐，还尝到了太顺杨梅。',
          },
        ),
      ],
      tags: const ['Visual'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineCardDetailBodySection(detail: detail),
        ),
      ),
    );

    expect(find.text('端午的温馨家常晚餐和太顺杨梅'), findsOneWidget);
    expect(find.text('一家人吃了家常晚餐，还尝到了太顺杨梅。'), findsOneWidget);
    expect(find.text('#Visual'), findsOneWidget);
    expect(find.textContaining('瑶瑶'), findsNothing);
    expect(find.textContaining('角色陪伴内容'), findsNothing);
  });

  testWidgets('renders raw fact markdown only when no structured config exists',
      (tester) async {
    final detail = _detail(
      rawContent: '## 晚餐记录\n- 家常菜\n- 太顺杨梅',
      uiConfigs: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineCardDetailBodySection(detail: detail),
        ),
      ),
    );

    expect(find.text('晚餐记录'), findsOneWidget);
    expect(find.text('家常菜'), findsOneWidget);
    expect(find.text('太顺杨梅'), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('falls back to raw fact when legacy html is empty',
      (tester) async {
    final detail = _detail(
      rawContent: '普通正文',
      uiConfigs: const [
        UiConfig(templateId: 'legacy_html', data: {'html': ''}),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineCardDetailBodySection(detail: detail),
        ),
      ),
    );

    expect(find.text('普通正文'), findsOneWidget);
  });
}

CardDetailModel _detail({
  required String rawContent,
  required List<UiConfig> uiConfigs,
  List<String> tags = const [],
}) {
  return CardDetailModel(
    id: '2026/06/20.md#ts_2',
    title: '端午的温馨家常晚餐和太顺杨梅',
    timestamp: DateTime(2026, 6, 20),
    address: '',
    tags: tags,
    rawContent: rawContent,
    insight: InsightData(
      text: '',
      relatedCards: const [],
      comments: const [],
    ),
    assets: const [],
    uiConfigs: uiConfigs,
  );
}
