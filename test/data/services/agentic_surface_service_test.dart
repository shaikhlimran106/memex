import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agentic_surface_service.dart';

void main() {
  group('AgenticSurfaceService', () {
    test('detects UI customization intents', () {
      expect(
        looksLikeAgenticSurfaceIntent('帮我做一个护眼紧凑的今日复盘页面'),
        isTrue,
      );
      expect(
        looksLikeAgenticSurfaceIntent('把这个 UI 的按钮改小一点'),
        isTrue,
      );
      expect(
        looksLikeAgenticSurfaceIntent('我今天拍了两张照片'),
        isFalse,
      );
      expect(
        looksLikeAgenticSurfaceIntent('昨天我做了什么'),
        isFalse,
      );
    });

    test('renders an interactive HTML surface with capability calls', () {
      final html = AgenticSurfaceService.renderHtmlForIntent(
        '帮我做一个护眼紧凑的今日复盘页面',
      );

      expect(html, contains('今日复盘'));
      expect(html, contains("memex.call('submit_record'"));
      expect(html, contains("memex.call('create_reminder'"));
      expect(html, contains("memex.call('get_context'"));
      expect(html, contains('护眼'));
      expect(html, contains('紧凑'));
    });
  });
}
