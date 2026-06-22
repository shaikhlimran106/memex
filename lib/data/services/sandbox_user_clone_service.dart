import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path/path.dart' as p;

class SandboxUserCloneResult {
  final String sourceUserId;
  final String targetUserId;
  final String sourceWorkspacePath;
  final String targetWorkspacePath;
  final int copiedFiles;
  final int copiedDirectories;
  final List<String> skippedPaths;

  const SandboxUserCloneResult({
    required this.sourceUserId,
    required this.targetUserId,
    required this.sourceWorkspacePath,
    required this.targetWorkspacePath,
    required this.copiedFiles,
    required this.copiedDirectories,
    required this.skippedPaths,
  });
}

class SandboxUserCloneService {
  static final SandboxUserCloneService instance = SandboxUserCloneService._();

  SandboxUserCloneService._();

  final _logger = getLogger('SandboxUserCloneService');

  static const Set<String> _defaultExcludedWorkspacePaths = {
    '_System/state_dir',
    '_System/llm_calls',
  };

  Future<SandboxUserCloneResult> cloneCurrentUserToLocalTestUser({
    String? targetUserId,
    bool overwriteTarget = false,
  }) async {
    final sourceUserId = await UserStorage.getUserId();
    if (sourceUserId == null || sourceUserId.isEmpty) {
      throw StateError('No active user to clone.');
    }

    final sourceDataRoot = await UserStorage.resolveDataRoot(sourceUserId);
    final targetDataRoot = await UserStorage.resolveDataRoot(null);
    final sourceWorkspacePath =
        p.join(sourceDataRoot, 'workspace', '_$sourceUserId');

    final sourceWorkspace = Directory(sourceWorkspacePath);
    if (!await sourceWorkspace.exists()) {
      throw FileSystemException(
        'Source workspace does not exist.',
        sourceWorkspacePath,
      );
    }

    final resolvedTargetUserId = await _resolveTargetUserId(
      sourceUserId: sourceUserId,
      requestedTargetUserId: targetUserId,
      targetDataRoot: targetDataRoot,
    );
    final targetWorkspacePath =
        p.join(targetDataRoot, 'workspace', '_$resolvedTargetUserId');
    final targetWorkspace = Directory(targetWorkspacePath);

    if (await targetWorkspace.exists()) {
      if (!overwriteTarget) {
        throw FileSystemException(
          'Target workspace already exists.',
          targetWorkspacePath,
        );
      }
    }

    final copyTargetWorkspace = overwriteTarget
        ? Directory(
            p.join(
              targetWorkspace.parent.path,
              '_${resolvedTargetUserId}_importing',
            ),
          )
        : targetWorkspace;
    if (await copyTargetWorkspace.exists()) {
      await copyTargetWorkspace.delete(recursive: true);
    }

    final copyStats = _CopyStats();
    try {
      await _copyDirectory(
        source: sourceWorkspace,
        target: copyTargetWorkspace,
        root: sourceWorkspace,
        stats: copyStats,
        excludedWorkspacePaths: _defaultExcludedWorkspacePaths,
      );
      if (overwriteTarget) {
        if (await targetWorkspace.exists()) {
          await targetWorkspace.delete(recursive: true);
        }
        await copyTargetWorkspace.rename(targetWorkspacePath);
      }
      await UserStorage.setWorkspaceStorageToApp(resolvedTargetUserId);
      _logger.info(
        'Cloned workspace from $sourceUserId to $resolvedTargetUserId. '
        'files=${copyStats.copiedFiles}, dirs=${copyStats.copiedDirectories}',
      );
      return SandboxUserCloneResult(
        sourceUserId: sourceUserId,
        targetUserId: resolvedTargetUserId,
        sourceWorkspacePath: sourceWorkspacePath,
        targetWorkspacePath: targetWorkspacePath,
        copiedFiles: copyStats.copiedFiles,
        copiedDirectories: copyStats.copiedDirectories,
        skippedPaths: List.unmodifiable(copyStats.skippedPaths),
      );
    } catch (e) {
      if (await copyTargetWorkspace.exists()) {
        await copyTargetWorkspace.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<String> _resolveTargetUserId({
    required String sourceUserId,
    required String? requestedTargetUserId,
    required String targetDataRoot,
  }) async {
    if (requestedTargetUserId != null && requestedTargetUserId.isNotEmpty) {
      return _sanitizeUserId(requestedTargetUserId);
    }

    const base = 'test';
    var candidate = base;
    var suffix = 2;
    while (await Directory(
      p.join(targetDataRoot, 'workspace', '_$candidate'),
    ).exists()) {
      candidate = '$base$suffix';
      suffix += 1;
    }
    return candidate;
  }

  static String _sanitizeUserId(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return sanitized.isEmpty ? 'test_user' : sanitized;
  }

  @visibleForTesting
  Future<void> copyWorkspaceDirectoryForTesting({
    required Directory source,
    required Directory target,
  }) async {
    await _copyDirectory(
      source: source,
      target: target,
      root: source,
      stats: _CopyStats(),
      excludedWorkspacePaths: _defaultExcludedWorkspacePaths,
    );
  }

  Future<void> _copyDirectory({
    required Directory source,
    required Directory target,
    required Directory root,
    required _CopyStats stats,
    required Set<String> excludedWorkspacePaths,
  }) async {
    await target.create(recursive: true);
    stats.copiedDirectories += 1;

    await for (final entity in source.list(followLinks: false)) {
      final relativePath = _workspaceRelativePath(entity.path, root.path);
      if (_shouldSkip(relativePath, excludedWorkspacePaths)) {
        stats.skippedPaths.add(relativePath);
        continue;
      }

      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(
          source: entity,
          target: Directory(targetPath),
          root: root,
          stats: stats,
          excludedWorkspacePaths: excludedWorkspacePaths,
        );
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
        stats.copiedFiles += 1;
      } else if (entity is Link) {
        stats.skippedPaths.add(relativePath);
      }
    }
  }

  static String _workspaceRelativePath(String entityPath, String rootPath) {
    final relative = p.relative(entityPath, from: rootPath);
    return p.split(relative).join('/');
  }

  static bool _shouldSkip(
    String relativePath,
    Set<String> excludedWorkspacePaths,
  ) {
    for (final excludedPath in excludedWorkspacePaths) {
      if (relativePath == excludedPath ||
          relativePath.startsWith('$excludedPath/')) {
        return true;
      }
    }
    return false;
  }
}

class _CopyStats {
  int copiedFiles = 0;
  int copiedDirectories = 0;
  final List<String> skippedPaths = [];
}
