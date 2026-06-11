import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ClipboardPreviewCandidateType { text, image }

class ClipboardPreviewCandidate {
  const ClipboardPreviewCandidate({
    required this.type,
    required this.hash,
    required this.previewText,
    this.text,
    this.imageUri,
    this.localPath,
    this.dataUri,
    this.mimeType,
    this.fileName,
    this.characterCount = 0,
  });

  final ClipboardPreviewCandidateType type;
  final String hash;
  final String previewText;
  final String? text;
  final String? imageUri;
  final String? localPath;
  final String? dataUri;
  final String? mimeType;
  final String? fileName;
  final int characterCount;

  bool get isText => type == ClipboardPreviewCandidateType.text;
  bool get isImage => type == ClipboardPreviewCandidateType.image;
}

class ClipboardPreviewService {
  static final ClipboardPreviewService instance = ClipboardPreviewService._();

  static const _channel = MethodChannel('com.memexlab.memex/clipboard_preview');
  static const _maxPreviewCharacters = 240;
  static const _maxHandledHashes = 80;
  static const _handledHashesKeyPrefix = 'clipboard_preview_handled_hashes_';
  static const _platformReadTimeout = Duration(milliseconds: 700);

  @visibleForTesting
  static bool debugUseBackgroundWorker = true;

  final _logger = getLogger('ClipboardPreviewService');

  ClipboardPreviewService._();

  Future<ClipboardPreviewCandidate?> fetchUnhandledCandidate({
    String? currentText,
  }) async {
    try {
      final summary = await _readClipboardSummary();
      if (summary == null) return null;

      if (summary.type == ClipboardPreviewCandidateType.text) {
        final text = summary.text?.trim();
        if (text == null || text.isEmpty) return null;

        final existingText = currentText?.trim();
        if (existingText != null &&
            existingText.isNotEmpty &&
            (existingText == text || existingText.contains(text))) {
          await markTextHandled(text);
          return null;
        }
      }

      final candidate = await _buildCandidate(summary);
      if (candidate == null) return null;

      final handledHashes = await _loadHandledHashes();
      if (handledHashes.contains(candidate.hash)) return null;

      return candidate;
    } catch (e, st) {
      _logger.warning('Failed to inspect clipboard: $e', e, st);
      return null;
    }
  }

  Future<ClipboardPreviewCandidate?> fetchUnhandledText({String? currentText}) {
    return fetchUnhandledCandidate(currentText: currentText);
  }

  Future<XFile?> materializeImage(ClipboardPreviewCandidate candidate) async {
    if (!candidate.isImage) return null;

    try {
      final localPath = candidate.localPath;
      if (localPath != null && await File(localPath).exists()) {
        return XFile(
          localPath,
          name: candidate.fileName,
          mimeType: candidate.mimeType,
        );
      }

      final dataUri = candidate.dataUri;
      if (dataUri != null) {
        final path = await _writeDataUriImageToCache(
          dataUri,
          candidate.mimeType,
        );
        return XFile(
          path,
          name: candidate.fileName ?? path.split(Platform.pathSeparator).last,
          mimeType: candidate.mimeType,
        );
      }

      final filePath = _filePathFromUri(candidate.imageUri);
      if (filePath != null && await File(filePath).exists()) {
        return XFile(
          filePath,
          name: candidate.fileName,
          mimeType: candidate.mimeType,
        );
      }

      final path = await _channel.invokeMethod<String>('copyImageToCache', {
        'uri': candidate.imageUri,
        'fileName': candidate.fileName,
        'mimeType': candidate.mimeType,
      });
      if (path == null || path.isEmpty) return null;
      return XFile(
        path,
        name: candidate.fileName ?? path.split(Platform.pathSeparator).last,
        mimeType: candidate.mimeType,
      );
    } on MissingPluginException {
      return null;
    } catch (e, st) {
      _logger.warning('Failed to materialize clipboard image: $e', e, st);
      return null;
    }
  }

  Future<void> markHandled(ClipboardPreviewCandidate candidate) {
    return _markHashHandled(candidate.hash);
  }

  Future<void> markTextHandled(String text) async {
    return _markHashHandled(await _hashText('text:${text.trim()}'));
  }

  Future<_ClipboardSummary?> _readClipboardSummary() async {
    final platformSummary = await _readPlatformClipboardSummary();
    if (platformSummary != null) return platformSummary;

    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) return null;
    return _summaryFromPlainText(text);
  }

  Future<_ClipboardSummary?> _readPlatformClipboardSummary() async {
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('getClipboardSummary')
          .timeout(_platformReadTimeout);
      if (raw == null) return null;
      return _ClipboardSummary.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on TimeoutException catch (e, st) {
      _logger.warning('Clipboard platform summary timed out: $e', e, st);
      return null;
    } catch (e, st) {
      _logger.warning('Clipboard platform summary failed: $e', e, st);
      return null;
    }
  }

  _ClipboardSummary _summaryFromPlainText(String text) {
    if (_isImageDataUri(text)) {
      return _ClipboardSummary(
        type: ClipboardPreviewCandidateType.image,
        dataUri: text,
        mimeType: _mimeTypeFromDataUri(text),
        sourceId: 'data:${text.length}:${_boundedSourceSlice(text)}',
      );
    }

    if (_looksLikeImageFileUri(text)) {
      return _ClipboardSummary(
        type: ClipboardPreviewCandidateType.image,
        imageUri: text,
        fileName: _fileNameFromUri(text),
        mimeType: _mimeTypeFromImagePath(text),
        sourceId: text,
      );
    }

    return _ClipboardSummary(
      type: ClipboardPreviewCandidateType.text,
      text: text,
    );
  }

  Future<ClipboardPreviewCandidate?> _buildCandidate(
    _ClipboardSummary summary,
  ) async {
    final data = await _runInBackground(_buildCandidateData, summary.toMap());
    if (data == null) return null;
    return ClipboardPreviewCandidate(
      type: data['type'] == 'image'
          ? ClipboardPreviewCandidateType.image
          : ClipboardPreviewCandidateType.text,
      hash: data['hash'] as String,
      previewText: data['previewText'] as String,
      text: data['text'] as String?,
      imageUri: data['imageUri'] as String?,
      localPath: data['localPath'] as String?,
      dataUri: data['dataUri'] as String?,
      mimeType: data['mimeType'] as String?,
      fileName: data['fileName'] as String?,
      characterCount: data['characterCount'] as int? ?? 0,
    );
  }

  Future<List<String>> _loadHandledHashes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(await _handledHashesKey()) ?? const [];
  }

  Future<void> _markHashHandled(String hash) async {
    if (hash.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _handledHashesKey();
      final hashes = prefs.getStringList(key) ?? <String>[];
      hashes.remove(hash);
      hashes.insert(0, hash);
      if (hashes.length > _maxHandledHashes) {
        hashes.removeRange(_maxHandledHashes, hashes.length);
      }
      await prefs.setStringList(key, hashes);
    } catch (e, st) {
      _logger.warning('Failed to mark clipboard as handled: $e', e, st);
    }
  }

  Future<String> _handledHashesKey() async {
    final userId = await UserStorage.getUserId();
    return '$_handledHashesKeyPrefix${userId ?? 'anonymous'}';
  }

  Future<String> _hashText(String text) {
    return _runInBackground(_hashTextSync, text);
  }

  Future<String> _writeDataUriImageToCache(
    String dataUri,
    String? mimeType,
  ) async {
    final directory = await getTemporaryDirectory();
    final extension = _extensionForMime(mimeType) ?? 'png';
    final outputPath =
        '${directory.path}/clipboard_image_${DateTime.now().millisecondsSinceEpoch}.$extension';
    return _runInBackground(_writeDataUriImageFile, {
      'dataUri': dataUri,
      'outputPath': outputPath,
    });
  }

  String? _filePathFromUri(String? uriString) {
    if (uriString == null || uriString.isEmpty) return null;
    final uri = Uri.tryParse(uriString);
    if (uri == null || !uri.hasScheme) return uriString;
    if (uri.scheme == 'file') return uri.toFilePath();
    return null;
  }
}

Future<R> _runInBackground<M, R>(
  ComputeCallback<M, R> callback,
  M message,
) {
  if (!ClipboardPreviewService.debugUseBackgroundWorker) {
    return Future.value(callback(message));
  }
  return compute(callback, message);
}

class _ClipboardSummary {
  const _ClipboardSummary({
    required this.type,
    this.text,
    this.imageUri,
    this.localPath,
    this.dataUri,
    this.mimeType,
    this.fileName,
    this.sourceId,
  });

  final ClipboardPreviewCandidateType type;
  final String? text;
  final String? imageUri;
  final String? localPath;
  final String? dataUri;
  final String? mimeType;
  final String? fileName;
  final String? sourceId;

  factory _ClipboardSummary.fromMap(Map<String, Object?> map) {
    final type = map['type'] == 'image'
        ? ClipboardPreviewCandidateType.image
        : ClipboardPreviewCandidateType.text;
    return _ClipboardSummary(
      type: type,
      text: map['text'] as String?,
      imageUri: map['uri'] as String?,
      localPath: map['localPath'] as String?,
      dataUri: map['dataUri'] as String?,
      mimeType: map['mimeType'] as String?,
      fileName: map['fileName'] as String?,
      sourceId: map['sourceId'] as String?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'type': type == ClipboardPreviewCandidateType.image ? 'image' : 'text',
      'text': text,
      'imageUri': imageUri,
      'localPath': localPath,
      'dataUri': dataUri,
      'mimeType': mimeType,
      'fileName': fileName,
      'sourceId': sourceId,
      'maxPreviewCharacters': ClipboardPreviewService._maxPreviewCharacters,
    };
  }
}

Map<String, Object?>? _buildCandidateData(Map<String, Object?> input) {
  final type = input['type'] as String?;
  if (type == 'image') {
    final sourceId = input['sourceId'] as String? ??
        input['imageUri'] as String? ??
        input['localPath'] as String? ??
        input['dataUri'] as String?;
    if (sourceId == null || sourceId.trim().isEmpty) return null;
    return {
      'type': 'image',
      'hash': _hashTextSync('image:$sourceId'),
      'previewText': '',
      'text': null,
      'imageUri': input['imageUri'] as String?,
      'localPath': input['localPath'] as String?,
      'dataUri': input['dataUri'] as String?,
      'mimeType': input['mimeType'] as String?,
      'fileName': input['fileName'] as String?,
      'characterCount': 0,
    };
  }

  final text = (input['text'] as String?)?.trim();
  if (text == null || text.isEmpty) return null;
  final maxPreviewCharacters = input['maxPreviewCharacters'] as int? ?? 240;
  return {
    'type': 'text',
    'hash': _hashTextSync('text:$text'),
    'previewText': _previewForText(text, maxPreviewCharacters),
    'text': text,
    'imageUri': null,
    'localPath': null,
    'dataUri': null,
    'mimeType': null,
    'fileName': null,
    'characterCount': text.runes.length,
  };
}

String _hashTextSync(String text) {
  if (text.isEmpty) return '';
  return sha256.convert(utf8.encode(text)).toString();
}

String _previewForText(String text, int maxCharacters) {
  final buffer = StringBuffer();
  var count = 0;
  var truncated = false;

  for (final rune in text.runes) {
    if (count >= maxCharacters) {
      truncated = true;
      break;
    }
    buffer.writeCharCode(rune);
    count += 1;
  }

  final preview = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return truncated ? '$preview...' : preview;
}

Future<String> _writeDataUriImageFile(Map<String, Object?> input) async {
  final dataUri = input['dataUri'] as String;
  final outputPath = input['outputPath'] as String;
  final commaIndex = dataUri.indexOf(',');
  if (commaIndex < 0) {
    throw const FormatException('Invalid image data URI');
  }
  final payload = dataUri.substring(commaIndex + 1);
  final bytes = base64.decode(payload);
  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return outputPath;
}

bool _isImageDataUri(String text) {
  return text.startsWith(RegExp(r'data:image/[a-zA-Z0-9.+-]+;base64,'));
}

String? _mimeTypeFromDataUri(String text) {
  final match = RegExp(r'^data:([^;,]+)').firstMatch(text);
  return match?.group(1);
}

bool _looksLikeImageFileUri(String text) {
  final uri = Uri.tryParse(text);
  final path = uri?.path ?? text;
  return _mimeTypeFromImagePath(path)?.startsWith('image/') ?? false;
}

String? _mimeTypeFromImagePath(String text) {
  final lower = text.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  return null;
}

String? _extensionForMime(String? mimeType) {
  switch (mimeType) {
    case 'image/jpeg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'image/heic':
      return 'heic';
    case 'image/heif':
      return 'heif';
    case 'image/bmp':
      return 'bmp';
  }
  return null;
}

String? _fileNameFromUri(String uriString) {
  final uri = Uri.tryParse(uriString);
  final path = uri?.path ?? uriString;
  if (path.isEmpty) return null;
  final segments = path.split('/');
  return segments.isEmpty ? null : segments.last;
}

String _boundedSourceSlice(String text) {
  if (text.length <= 256) return text;
  return '${text.substring(0, 128)}:${text.substring(text.length - 128)}';
}
