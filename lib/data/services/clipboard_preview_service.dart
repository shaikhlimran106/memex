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
  static const _lastHandledTokenKeyPrefix =
      'clipboard_preview_last_handled_token_';
  static const _platformReadTimeout = Duration(milliseconds: 700);

  @visibleForTesting
  static bool debugUseBackgroundWorker = true;

  final _logger = getLogger('ClipboardPreviewService');

  ClipboardPreviewService._();

  Future<ClipboardPreviewCandidate?> fetchUnhandledCandidate({
    String? currentText,
  }) async {
    try {
      _logger.info('Checking clipboard preview candidate');
      final summary = await _readClipboardSummary();
      if (summary == null) {
        _logger.info('Clipboard preview skipped: no readable summary');
        return null;
      }
      _logger.info('Clipboard summary: ${_describeSummary(summary)}');

      if (summary.type == ClipboardPreviewCandidateType.text) {
        final text = summary.text?.trim();
        if (text == null || text.isEmpty) {
          _logger.info('Clipboard preview skipped: empty summary text');
          return null;
        }

        final existingText = currentText?.trim();
        if (existingText != null &&
            existingText.isNotEmpty &&
            (existingText == text || existingText.contains(text))) {
          _logger.info(
            'Clipboard preview skipped: text already in current input, '
            'len=${text.runes.length}, preview=${_logPreview(text)}',
          );
          await markTextHandled(text);
          return null;
        }
      }

      final candidate = await _buildCandidate(summary);
      if (candidate == null) {
        _logger
            .info('Clipboard preview skipped: candidate build returned null');
        return null;
      }

      final lastHandledToken = await _loadLastHandledToken();
      if (lastHandledToken == candidate.hash) {
        _logger.info(
          'Clipboard preview skipped: matches last handled token '
          'type=${candidate.type.name}, hash=${_shortHash(candidate.hash)}',
        );
        return null;
      }

      _logger.info(
          'Clipboard preview candidate ready: ${_describeCandidate(candidate)}');
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
    final platformRead = await _readPlatformClipboardSummary();
    if (platformRead.summary != null) return platformRead.summary;

    _logger
        .info('Native clipboard summary empty; trying Flutter text fallback');
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) {
      _logger.info('Flutter text fallback empty');
      return null;
    }
    _logger.info(
      'Flutter text fallback read: len=${text.runes.length}, '
      'preview=${_logPreview(text)}',
    );
    return _summaryFromPlainText(text);
  }

  Future<_PlatformClipboardRead> _readPlatformClipboardSummary() async {
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('getClipboardSummary')
          .timeout(_platformReadTimeout);
      if (raw == null) {
        _logger.info('Native clipboard summary returned null');
        return const _PlatformClipboardRead();
      }
      _logger.info('Native clipboard summary raw: ${_describeRawSummary(raw)}');
      return _PlatformClipboardRead(summary: _ClipboardSummary.fromMap(raw));
    } on MissingPluginException {
      _logger
          .info('Clipboard platform channel missing; using Flutter fallback');
      return const _PlatformClipboardRead();
    } on TimeoutException catch (e, st) {
      _logger.warning('Clipboard platform summary timed out: $e', e, st);
      return const _PlatformClipboardRead();
    } catch (e, st) {
      _logger.warning('Clipboard platform summary failed: $e', e, st);
      return const _PlatformClipboardRead();
    }
  }

  _ClipboardSummary _summaryFromPlainText(String text) {
    if (_isImageDataUri(text)) {
      _logger.info('Plain text summary interpreted as image data URI');
      return _ClipboardSummary(
        type: ClipboardPreviewCandidateType.image,
        dataUri: text,
        mimeType: _mimeTypeFromDataUri(text),
        sourceId: 'data:${text.length}:${_boundedSourceSlice(text)}',
      );
    }

    if (_looksLikeImageFileUri(text)) {
      _logger.info(
        'Plain text summary interpreted as image file URI: ${_logPreview(text)}',
      );
      return _ClipboardSummary(
        type: ClipboardPreviewCandidateType.image,
        imageUri: text,
        fileName: _fileNameFromUri(text),
        mimeType: _mimeTypeFromImagePath(text),
        sourceId: text,
      );
    }

    _logger.info(
      'Plain text summary interpreted as text: len=${text.runes.length}, '
      'preview=${_logPreview(text)}',
    );
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

  Future<String?> _loadLastHandledToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(await _lastHandledTokenKey());
  }

  Future<void> _markHashHandled(String hash) async {
    if (hash.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(await _lastHandledTokenKey(), hash);
    } catch (e, st) {
      _logger.warning('Failed to mark clipboard as handled: $e', e, st);
    }
  }

  Future<String> _lastHandledTokenKey() async {
    final userId = await UserStorage.getUserId();
    return '$_lastHandledTokenKeyPrefix${userId ?? 'anonymous'}';
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

  String _describeRawSummary(Map<String, Object?> raw) {
    final type = raw['type'];
    final text = raw['text'] as String?;
    return 'type=$type, textLen=${text?.runes.length ?? 0}, '
        'preview=${_logPreview(text)}, uri=${_logPreview(raw['uri'] as String?)}, '
        'localPath=${_logPreview(raw['localPath'] as String?)}, '
        'dataUri=${raw['dataUri'] == null ? '<none>' : '<present>'}, '
        'mimeType=${raw['mimeType']}, fileName=${raw['fileName']}, '
        'sourceId=${_logPreview(raw['sourceId'] as String?)}';
  }

  String _describeSummary(_ClipboardSummary summary) {
    return 'type=${summary.type.name}, '
        'textLen=${summary.text?.runes.length ?? 0}, '
        'preview=${_logPreview(summary.text)}, '
        'imageUri=${_logPreview(summary.imageUri)}, '
        'localPath=${_logPreview(summary.localPath)}, '
        'dataUri=${summary.dataUri == null ? '<none>' : '<present>'}, '
        'mimeType=${summary.mimeType}, fileName=${summary.fileName}, '
        'sourceId=${_logPreview(summary.sourceId)}';
  }

  String _describeCandidate(ClipboardPreviewCandidate candidate) {
    return 'type=${candidate.type.name}, hash=${_shortHash(candidate.hash)}, '
        'textLen=${candidate.text?.runes.length ?? 0}, '
        'preview=${_logPreview(candidate.text)}, '
        'imageUri=${_logPreview(candidate.imageUri)}, '
        'localPath=${_logPreview(candidate.localPath)}, '
        'dataUri=${candidate.dataUri == null ? '<none>' : '<present>'}, '
        'mimeType=${candidate.mimeType}, fileName=${candidate.fileName}';
  }

  String _shortHash(String hash) {
    return hash.length <= 10 ? hash : hash.substring(0, 10);
  }

  String _logPreview(String? value) {
    if (value == null || value.isEmpty) return '<none>';
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '<blank>';
    return normalized.length <= 96
        ? normalized
        : '${normalized.substring(0, 96)}...';
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

class _PlatformClipboardRead {
  const _PlatformClipboardRead({this.summary});

  final _ClipboardSummary? summary;
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
  if (_looksLikeBinaryClipboardText(text)) return null;
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

bool _looksLikeBinaryClipboardText(String text) {
  if (text.contains('\u0000')) return true;
  if (text.startsWith('\u0089PNG') || text.contains('PNG\r\n\u001A\n')) {
    return true;
  }
  if (text.contains('JFIF\u0000') || text.contains('Exif\u0000')) {
    return true;
  }

  var controlCount = 0;
  var replacementCount = 0;
  var total = 0;

  for (final rune in text.runes) {
    total += 1;
    final isAllowedWhitespace = rune == 0x09 || rune == 0x0A || rune == 0x0D;
    final isControl = !isAllowedWhitespace &&
        ((rune >= 0x00 && rune <= 0x1F) || (rune >= 0x7F && rune <= 0x9F));
    if (isControl) controlCount += 1;
    if (rune == 0xFFFD) replacementCount += 1;
  }

  if (total == 0) return false;
  if (controlCount >= 3 || controlCount / total > 0.02) return true;
  if (replacementCount >= 8 || replacementCount / total > 0.08) return true;
  return false;
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
