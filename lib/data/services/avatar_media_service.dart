import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:memex/data/services/asset_safety_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AvatarMediaService {
  AvatarMediaService._();

  static const _diceBearTimeout = Duration(seconds: 10);

  static bool isImageAvatar(String? avatar) {
    final value = avatar?.trim();
    if (value == null || value.isEmpty) return false;

    return value.startsWith('fs://') ||
        _isRemoteUri(value) ||
        p.isAbsolute(value) ||
        hasSupportedImageExtension(value) ||
        value.contains('/');
  }

  static bool isDiceBearSeed(String? avatar) {
    final value = avatar?.trim();
    return value != null && value.isNotEmpty && !isImageAvatar(value);
  }

  static bool isRelativeImagePath(String avatar) {
    final value = avatar.trim();
    if (value.isEmpty || p.isAbsolute(value)) return false;
    if (value.startsWith('fs://') || _isRemoteUri(value)) return false;
    return hasSupportedImageExtension(value);
  }

  static bool hasSupportedImageExtension(String value) {
    final ext = p.extension(_pathForExtension(value)).toLowerCase();
    return AssetSafetyService.imageExtensions.contains(ext);
  }

  static String resolveAvatarPath(
    String avatar, {
    required FileSystemService fileSystemService,
  }) {
    if (isRelativeImagePath(avatar)) {
      return fileSystemService.toAbsolutePath(avatar);
    }
    return avatar;
  }

  static void precacheDiceBearAvatar(String? avatar) {
    if (!isDiceBearSeed(avatar)) return;
    unawaited(cacheDiceBearSvg(avatar!.trim()));
  }

  static String diceBearUrl(String seed) {
    final encoded = Uri.encodeComponent(seed);
    return 'https://api.dicebear.com/7.x/notionists/svg?seed=$encoded';
  }

  static Future<File> diceBearCacheFile(String seed) async {
    final dir = await getApplicationSupportDirectory();
    final hash = md5.convert(utf8.encode(seed)).toString();
    return File(p.join(dir.path, 'avatar_$hash.svg'));
  }

  static Future<File?> loadDiceBearSvg(String seed) async {
    final file = await diceBearCacheFile(seed);
    if (await file.exists() && await file.length() > 0) {
      return file;
    }

    final cachedPath = await cacheDiceBearSvg(seed);
    if (cachedPath == null) return null;
    return File(cachedPath);
  }

  static Future<String?> cacheDiceBearSvg(
    String seed, {
    http.Client? client,
    Duration timeout = _diceBearTimeout,
  }) async {
    final cleanSeed = seed.trim();
    if (cleanSeed.isEmpty) return null;

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(Uri.parse(diceBearUrl(cleanSeed)))
          .timeout(timeout);
      if (response.statusCode != 200 || response.body.trim().isEmpty) {
        return null;
      }

      final file = await diceBearCacheFile(cleanSeed);
      await file.parent.create(recursive: true);
      await file.writeAsString(response.body);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) {
        httpClient.close();
      }
    }
  }

  static String _pathForExtension(String value) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      return uri.path;
    }
    return value.split('?').first.split('#').first;
  }

  static bool _isRemoteUri(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
