import 'dart:io';

import 'package:memex/data/services/asset_safety_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:path/path.dart' as p;

enum AssetReferenceType { image, audio }

class AssetReference {
  const AssetReference({
    required this.fileName,
    required this.absolutePath,
    required this.type,
  });

  final String fileName;
  final String absolutePath;
  final AssetReferenceType type;

  String get fsUri => 'fs://$fileName';

  String get markdownRef => switch (type) {
        AssetReferenceType.image => '![image]($fsUri)',
        AssetReferenceType.audio => '[audio]($fsUri)',
      };
}

class AssetReferenceService {
  AssetReferenceService._();

  static final _markdownFsPattern = RegExp(r'\(fs://([^)]+)\)');

  static List<String> extractFileNames(String text) {
    return extractReferences(text)
        .map(extractFileNameFromReference)
        .whereType<String>()
        .toList();
  }

  static List<String> extractReferences(String text) {
    final seen = <String>{};
    final references = <String>[];
    for (final fileName in _extractFileNamesAfterFsScheme(text)) {
      final reference = 'fs://$fileName';
      if (!seen.add(reference)) continue;
      references.add(reference);
    }
    return references;
  }

  static String? extractFileNameFromReference(String reference) {
    final markdownMatch = _markdownFsPattern.firstMatch(reference);
    if (markdownMatch != null) {
      return _cleanFileName(markdownMatch.group(1));
    }
    final fileNames = _extractFileNamesAfterFsScheme(reference);
    if (fileNames.isEmpty) return null;
    return _cleanFileName(fileNames.first);
  }

  static Future<AssetReference?> resolveExisting({
    required String userId,
    required String reference,
  }) async {
    final fileName = extractFileNameFromReference(reference);
    if (fileName == null) return null;
    return resolveExistingFileName(userId: userId, fileName: fileName);
  }

  static Future<AssetReference?> resolveExistingFileName({
    required String userId,
    required String fileName,
  }) async {
    final clean = _cleanFileName(fileName);
    if (clean == null) return null;

    final type = _typeForFileName(clean);
    if (type == null) return null;

    final assetsPath = FileSystemService.instance.getAssetsPath(userId);
    final absolutePath = p.join(assetsPath, clean);
    if (!await File(absolutePath).exists()) return null;

    return AssetReference(
      fileName: clean,
      absolutePath: absolutePath,
      type: type,
    );
  }

  static String? _cleanFileName(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (p.isAbsolute(value)) return null;
    final normalized = p.normalize(value);
    if (normalized == '.' || normalized.startsWith('..')) return null;
    if (normalized != p.basename(normalized)) return null;
    return normalized;
  }

  static List<String> _extractFileNamesAfterFsScheme(String text) {
    final out = <String>[];
    var searchStart = 0;
    while (searchStart < text.length) {
      final schemeIndex = text.indexOf('fs://', searchStart);
      if (schemeIndex < 0) break;
      final afterScheme = schemeIndex + 'fs://'.length;
      final end = _findSupportedExtensionEnd(text, afterScheme);
      if (end == null) {
        searchStart = afterScheme;
        continue;
      }
      final candidate = text.substring(afterScheme, end);
      final clean = _cleanFileName(candidate);
      if (clean != null) out.add(clean);
      searchStart = end;
    }
    return out;
  }

  static int? _findSupportedExtensionEnd(String text, int start) {
    int? bestEnd;
    final tail = text.substring(start);
    for (final extension in _supportedExtensions) {
      final pattern = RegExp('${RegExp.escape(extension)}(?![A-Za-z0-9])',
          caseSensitive: false);
      final match = pattern.firstMatch(tail);
      if (match == null) continue;
      final end = start + match.end;
      if (bestEnd == null || end < bestEnd) {
        bestEnd = end;
      }
    }
    return bestEnd;
  }

  static final Set<String> _supportedExtensions = {
    ...AssetSafetyService.imageExtensions,
    ...AssetSafetyService.audioExtensions,
  };

  static AssetReferenceType? _typeForFileName(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    if (AssetSafetyService.imageExtensions.contains(extension)) {
      return AssetReferenceType.image;
    }
    if (AssetSafetyService.audioExtensions.contains(extension)) {
      return AssetReferenceType.audio;
    }
    return null;
  }
}
