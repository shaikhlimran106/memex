import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ClipboardPreviewCandidate {
  const ClipboardPreviewCandidate({required this.text, required this.hash});

  final String text;
  final String hash;

  int get characterCount => text.runes.length;

  String get previewText => text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class ClipboardPreviewService {
  static final ClipboardPreviewService instance = ClipboardPreviewService._();

  static const _maxHandledHashes = 80;
  static const _handledHashesKeyPrefix = 'clipboard_preview_handled_hashes_';

  final _logger = getLogger('ClipboardPreviewService');

  ClipboardPreviewService._();

  Future<ClipboardPreviewCandidate?> fetchUnhandledText({
    String? currentText,
  }) async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim();
      if (text == null || text.isEmpty) return null;

      final existingText = currentText?.trim();
      if (existingText != null &&
          existingText.isNotEmpty &&
          (existingText == text || existingText.contains(text))) {
        await markTextHandled(text);
        return null;
      }

      final hash = _hashText(text);
      final handledHashes = await _loadHandledHashes();
      if (handledHashes.contains(hash)) return null;

      return ClipboardPreviewCandidate(text: text, hash: hash);
    } catch (e, st) {
      _logger.warning('Failed to inspect clipboard: $e', e, st);
      return null;
    }
  }

  Future<void> markHandled(ClipboardPreviewCandidate candidate) {
    return _markHashHandled(candidate.hash);
  }

  Future<void> markTextHandled(String text) {
    return _markHashHandled(_hashText(text.trim()));
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

  String _hashText(String text) {
    if (text.isEmpty) return '';
    return sha256.convert(utf8.encode(text)).toString();
  }
}
