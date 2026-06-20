import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/agent_background_platform.dart';
import 'package:memex/data/services/agent_background_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.memexlab.memex/agent_background';
  const channel = MethodChannel(channelName);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes summary through updateAgentStatus platform payload', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final platform = MethodChannelAgentBackgroundPlatform(channel: channel);

    await platform.updateStatus(
      AgentBackgroundStatus(
        state: AgentBackgroundRunState.active,
        pending: 1,
        processing: 1,
        retrying: 0,
        title: 'Memex Agent',
        stage: 'Calling Tool',
        detail: 'Refreshing timeline',
        summary: 'Refreshing timeline',
        agentName: 'Timeline Agent',
        scene: 'timeline',
        sceneId: 'card-1',
        updatedAt: DateTime(2026, 1, 1),
      ),
      isInBackground: true,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateAgentStatus');
    final payload = calls.single.arguments as Map<Object?, Object?>;
    expect(payload['title'], 'Memex Agent');
    expect(payload['stage'], 'Calling Tool');
    expect(payload['detail'], 'Refreshing timeline');
    expect(payload['summary'], 'Refreshing timeline');
    expect(payload['summary'], isNot(contains('Calling Tool')));
    expect(payload['remainingTasks'], 2);
    expect(payload['isInBackground'], isTrue);
    expect(payload['scene'], 'timeline');
    expect(payload['sceneId'], 'card-1');
  });

  test('passes summary through finishAgentStatus platform payload', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final platform = MethodChannelAgentBackgroundPlatform(channel: channel);

    await platform.finishStatus(
      AgentBackgroundStatus(
        state: AgentBackgroundRunState.failed,
        pending: 0,
        processing: 0,
        retrying: 0,
        title: 'Memex Agent needs attention',
        stage: 'Provider error',
        detail: 'API key is missing',
        summary: 'API key is missing',
        agentName: 'Insight Agent',
        updatedAt: DateTime(2026, 1, 1),
      ),
      isInBackground: true,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'finishAgentStatus');
    final payload = calls.single.arguments as Map<Object?, Object?>;
    expect(payload['state'], 'failed');
    expect(payload['title'], 'Memex Agent needs attention');
    expect(payload['detail'], 'API key is missing');
    expect(payload['summary'], 'API key is missing');
    expect(payload['isInBackground'], isTrue);
  });

  test(
    'emits action event when Android asks Flutter to open agent activity',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = MethodChannelAgentBackgroundPlatform(channel: channel);
      final events = <String>[];
      final subscription = platform.actionStream.listen(events.add);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('openAgentActivity'),
            ),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);

      expect(events, ['agent_activity']);
      await subscription.cancel();
    },
  );
}
