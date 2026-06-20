import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/ui/settings/widgets/agent_run_trace_viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'user_id': 'trace-user'});
  });

  testWidgets('lists and opens agent run trace markdown', (tester) async {
    const traceContent = '''
# Agent Run Trace

## Plan

- inspect context

## Tool Started: `Read`

## Final Response

done
''';

    await tester.pumpWidget(
      MaterialApp(
        home: AgentRunTraceViewerPage(
          enableTextSelection: false,
          traceEntriesForTesting: [
            AgentRunTraceViewerEntry(
              path: '/traces/2026-06-20/task-123/trace.md',
              title: '2026-06-20',
              subtitle: 'task-123',
              modified: DateTime(2026, 6, 20, 12),
              readContent: () async => traceContent,
            ),
          ],
          userIdForTesting: 'trace-user',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Agent Run Traces'), findsOneWidget);
    expect(find.text('2026-06-20'), findsOneWidget);
    expect(find.text('task-123'), findsOneWidget);
    expect(find.textContaining('# Agent Run Trace'), findsOneWidget);
    expect(find.textContaining('inspect context'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Final Response');
    await tester.pump();

    expect(find.text('## Final Response'), findsOneWidget);
    expect(find.textContaining('inspect context'), findsNothing);
  });
}
