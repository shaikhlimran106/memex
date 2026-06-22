import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as path;
import 'package:memex/data/services/file_system_service.dart';

/// Audio source helper: local server URL and local file path
/// - If URL starts with http://127.0.0.1, parse as local path and use DeviceFileSource
/// - If URL does not start with http (local path), use DeviceFileSource
/// - else use UrlSource for network audio
class LocalAudioSource {
  /// Parse file path from local server URL
  /// URL format: http://127.0.0.1:port/assets/{userId}/{filename}?token=xxx
  /// file path format: {dataRoot}/workspace/_{userId}/Facts/assets/{filename}
  static String? _parseLocalFilePath(String url) {
    if (!url.startsWith('http://127.0.0.1')) {
      return null;
    }

    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;

      // path format: /assets/{userId}/{filename}
      if (pathSegments.length < 3 || pathSegments[0] != 'assets') {
        return null;
      }

      final userId = Uri.decodeComponent(pathSegments[1]);
      final filename = pathSegments
          .sublist(2)
          .map(Uri.decodeComponent)
          .join(Platform.pathSeparator);

      // Get FileSystemService instance
      try {
        final fileSystemService = FileSystemService.instance;
        final dataRoot = fileSystemService.dataRoot;

        // build file path: {dataRoot}/workspace/_{userId}/Facts/assets/{filename}
        final workspacePath = path.join(dataRoot, 'workspace', '_$userId');
        final assetsPath = path.join(workspacePath, 'Facts', 'assets');
        final filePath = path.join(assetsPath, filename);

        return filePath;
      } catch (e) {
        // FileSystemService not initialized, return null
        return null;
      }
    } catch (e) {
      // URL parse fails, return null
      return null;
    }
  }

  /// Create appropriate audio source from URL
  /// Returns DeviceFileSource (local) or UrlSource (network URL)
  static Source createSource(String url) {
    // try parse local file path (from http://127.0.0.1 URL)
    final localFilePath = _parseLocalFilePath(url);

    // check if local file path
    final isLocalFile = localFilePath != null || !url.startsWith('http');

    if (isLocalFile) {
      // use local file path
      final filePath = localFilePath ?? url;
      return DeviceFileSource(filePath);
    } else {
      // use network URL
      return UrlSource(url);
    }
  }
}
