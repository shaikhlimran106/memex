import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memex/data/services/avatar_media_service.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memex_avatar_media_');
    _mockPathProviderChannel(tempDir.path);
    await FileSystemService.init(tempDir.path);
  });

  tearDown(() async {
    _clearPathProviderChannelMock();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('recognizes all imported image extensions as avatar image paths', () {
    for (final ext in const [
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'bmp',
      'heic',
      'heif',
      'tiff',
      'tif',
    ]) {
      final relative = 'workspace/_user/_System/media/avatar.$ext';

      expect(AvatarMediaService.isImageAvatar(relative), isTrue, reason: ext);
      expect(
        AvatarMediaService.isRelativeImagePath(relative),
        isTrue,
        reason: ext,
      );
    }
  });

  test('resolves relative avatar media paths against current data root', () {
    const relative = 'workspace/_user/_System/media/avatar.heic';

    final resolved = AvatarMediaService.resolveAvatarPath(
      relative,
      fileSystemService: FileSystemService.instance,
    );

    expect(resolved, p.join(tempDir.path, relative));
  });

  test(
    'keeps DiceBear seeds and remote images out of relative path resolution',
    () {
      expect(AvatarMediaService.isDiceBearSeed('Felix'), isTrue);
      expect(AvatarMediaService.isImageAvatar('Felix'), isFalse);
      expect(AvatarMediaService.isRelativeImagePath('Felix'), isFalse);

      const remote = 'https://example.com/avatar.heic';
      expect(AvatarMediaService.isImageAvatar(remote), isTrue);
      expect(AvatarMediaService.isRelativeImagePath(remote), isFalse);
    },
  );

  test('caches DiceBear SVGs to application support directory', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), contains('seed=Felix'));
      return http.Response(_svgBody, 200);
    });

    final cachedPath = await AvatarMediaService.cacheDiceBearSvg(
      'Felix',
      client: client,
    );

    expect(cachedPath, isNotNull);
    final cached = File(cachedPath!);
    expect(await cached.exists(), isTrue);
    expect(await cached.readAsString(), _svgBody);
  });

  test(
    'returns null without creating a cache file on download failure',
    () async {
      final client = MockClient((request) async => http.Response('nope', 503));

      final cachedPath = await AvatarMediaService.cacheDiceBearSvg(
        'offline',
        client: client,
      );
      final cacheFile = await AvatarMediaService.diceBearCacheFile('offline');

      expect(cachedPath, isNull);
      expect(await cacheFile.exists(), isFalse);
    },
  );
}

const _svgBody =
    '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48">'
    '<rect width="48" height="48" fill="#5B6CFF"/></svg>';

void _mockPathProviderChannel(String rootPath) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationSupportDirectory':
        case 'getExternalStorageDirectory':
          return rootPath;
        case 'getExternalStorageDirectories':
          return <String>[rootPath];
      }
      return null;
    },
  );
}

void _clearPathProviderChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    null,
  );
}
