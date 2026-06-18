import 'package:flutter_test/flutter_test.dart';
import 'package:memex/agent/security/file_permission_manager.dart';
import 'package:memex/agent/super_agent/super_agent.dart';

void main() {
  const workspace = '/ws/_u';
  const facts = '/ws/_u/Facts';
  const assets = '/ws/_u/Facts/assets';

  FilePermissionManager managerFor({required bool quickQuery}) {
    return FilePermissionManager(
      'test_user',
      SuperAgent.buildPermissionRules(
        workspacePath: workspace,
        factsPath: facts,
        factsAssetsPath: assets,
        quickQuery: quickQuery,
      ),
      withDefaultRules: false,
    );
  }

  group('SuperAgent file permissions (normal mode)', () {
    final manager = managerFor(quickQuery: false);

    test('daily fact markdown is read-only', () {
      expect(
        () => manager.checkPermission(
            '$facts/2026/06/10.md', FileAccessType.write),
        throwsA(isA<PermissionDeniedException>()),
      );
      // Reading stays allowed.
      manager.checkPermission('$facts/2026/06/10.md', FileAccessType.read);
    });

    test('moving or removing a fact file is denied (write on source)', () {
      expect(
        () => manager.checkPermission('$facts/2026/06', FileAccessType.write),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('derived analysis sidecars under assets stay writable', () {
      manager.checkPermission(
          '$assets/photo.jpg.analysis.txt', FileAccessType.write);
      manager.checkPermission(
          '$assets/voice.m4a.ocr.txt', FileAccessType.write);
    });

    test('the rest of the workspace stays writable', () {
      manager.checkPermission(
          '$workspace/Cards/2026_06_10.yaml', FileAccessType.write);
      manager.checkPermission('$workspace/PKM/note.md', FileAccessType.write);
    });
  });

  group('SuperAgent file permissions (quick query)', () {
    final manager = managerFor(quickQuery: true);

    test('everything is read-only including assets', () {
      manager.checkPermission('$facts/2026/06/10.md', FileAccessType.read);
      expect(
        () => manager.checkPermission(
            '$assets/photo.jpg.analysis.txt', FileAccessType.write),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(
        () => manager.checkPermission(
            '$workspace/Cards/c.yaml', FileAccessType.write),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('SuperAgent quick query tools', () {
    test('does not expose event log search or current time tools', () {
      expect(
        SuperAgent.isQuickQueryToolAllowed('search_workspace_event_logs'),
        isFalse,
      );
      expect(
        SuperAgent.isQuickQueryToolAllowed('getCurrentTime'),
        isFalse,
      );
    });

    test('allows image viewing as a read-only tool', () {
      expect(SuperAgent.isQuickQueryToolAllowed('view_image'), isTrue);
    });

    test('uses generic LS for PKM reads instead of PKM overview tool', () {
      expect(SuperAgent.isQuickQueryToolAllowed('LS'), isTrue);
      expect(SuperAgent.isQuickQueryToolAllowed('get_pkm_overview'), isFalse);
    });
  });
}
