import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/sandbox_user_clone_service.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
    await UserStorage.saveUser('real_user');

    tempDir = await Directory.systemTemp.createTemp('memex_sandbox_clone_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('clones workspace content while skipping agent runtime state', () async {
    final sourceWorkspace =
        Directory(p.join(tempDir.path, 'workspace', '_real_user'));
    await sourceWorkspace.create(recursive: true);

    final cardFile = File(p.join(sourceWorkspace.path, 'Cards', 'card.yaml'));
    await cardFile.create(recursive: true);
    await cardFile.writeAsString('title: copied card');

    final eventLogFile = File(
      p.join(sourceWorkspace.path, '_System', 'EventLogs', 'today.jsonl'),
    );
    await eventLogFile.create(recursive: true);
    await eventLogFile.writeAsString('{}');

    final stateFile = File(
      p.join(sourceWorkspace.path, '_System', 'state_dir', 'agent.json'),
    );
    await stateFile.create(recursive: true);
    await stateFile.writeAsString('{}');

    final llmCallFile = File(
      p.join(sourceWorkspace.path, '_System', 'llm_calls', 'call.json'),
    );
    await llmCallFile.create(recursive: true);
    await llmCallFile.writeAsString('{}');

    final result = await SandboxUserCloneService.instance
        .cloneCurrentUserToLocalTestUser(targetUserId: 'test_clone');

    expect(result.sourceUserId, 'real_user');
    expect(result.targetUserId, 'test_clone');
    expect(await UserStorage.getUserId(), 'real_user');

    final targetWorkspace =
        Directory(p.join(tempDir.path, 'workspace', '_test_clone'));
    expect(await targetWorkspace.exists(), isTrue);
    expect(
      await File(p.join(targetWorkspace.path, 'Cards', 'card.yaml')).exists(),
      isTrue,
    );
    expect(
      await File(
        p.join(targetWorkspace.path, '_System', 'EventLogs', 'today.jsonl'),
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        p.join(targetWorkspace.path, '_System', 'state_dir', 'agent.json'),
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        p.join(targetWorkspace.path, '_System', 'llm_calls', 'call.json'),
      ).exists(),
      isFalse,
    );
    expect(result.skippedPaths, contains('_System/state_dir'));
    expect(result.skippedPaths, contains('_System/llm_calls'));
  });
}

class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
