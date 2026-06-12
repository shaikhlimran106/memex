import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/repositories/submit_input.dart';
import 'package:memex/data/services/agent_run_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/local_asset_server.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('submitInput', () {
    late Directory root;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await UserStorage.initL10n();
      root = await Directory.systemTemp.createTemp('memex_submit_input_');
      await FileSystemService.init(root.path);
      setSubmitInputAgentRunServiceForTesting(null);
    });

    tearDown(() async {
      setSubmitInputAgentRunServiceForTesting(null);
      await LocalAssetServer.stopServer();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('continues when durable agent run persistence fails', () async {
      final agentRunService = _ThrowingAgentRunService();
      setSubmitInputAgentRunServiceForTesting(agentRunService);

      final result = await submitInput('submit-input-user', [
        {'type': 'text', 'text': 'note survives run persistence failure'},
      ]);

      final factId = result['fact_id'] as String;
      final factPath = factId.split('#').first;
      final factFile = File(
        p.join(
          FileSystemService.instance.getFactsPath('submit-input-user'),
          factPath,
        ),
      );
      final cardFile = File(
        FileSystemService.instance.getCardPath('submit-input-user', factId),
      );

      expect(result['card'], isA<Map<String, dynamic>>());
      expect(await factFile.readAsString(), contains('note survives'));
      expect(cardFile.existsSync(), isTrue);
      expect(agentRunService.createCalls, 1);
      expect(agentRunService.refreshCalls, 1);
    });
  });
}

class _ThrowingAgentRunService extends AgentRunService {
  _ThrowingAgentRunService() : super.forTesting();

  int createCalls = 0;
  int refreshCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<void> createForSubmittedInput({
    required String userId,
    required String factId,
  }) async {
    createCalls++;
    throw StateError('create failed');
  }

  @override
  Future<void> refreshRunFromTasks(String runId) async {
    refreshCalls++;
    throw StateError('refresh failed');
  }
}
