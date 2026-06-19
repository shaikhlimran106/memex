import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logging/logging.dart';
import 'package:share_handler/share_handler.dart';

import 'package:memex/data/services/backup_import_intent_service.dart';
import 'package:memex/data/services/backup_service.dart';
import 'package:memex/utils/toast_helper.dart';
import 'package:memex/utils/user_storage.dart';

class SharedDraft {
  const SharedDraft({
    this.text,
    this.images = const [],
  });

  final String? text;
  final List<XFile> images;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && images.isEmpty;
}

/// Handles system share intents (text, images) and forwards them
/// as drafts into the Super Agent dialog for user confirmation.
class ShareIntentHandler {
  final Logger logger;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;
  final void Function(SharedDraft) onSharedDraft;
  final Future<void> Function(String backupFilePath) onBackupFileShared;

  StreamSubscription<SharedMedia>? _mediaSubscription;
  StreamSubscription<String>? _backupPathSubscription;
  bool _isHandlingShare = false;
  bool _isHandlingBackupFile = false;

  ShareIntentHandler({
    required this.logger,
    required this.scaffoldMessengerKey,
    required this.onSharedDraft,
    required this.onBackupFileShared,
  });

  void init() {
    final handler = ShareHandlerPlatform.instance;

    // Handle initial shared media when app is launched from share
    handler.getInitialSharedMedia().then((media) {
      if (media != null) {
        _handleSharedMedia(media);
      }
    });

    // Listen for media shared while app is in memory
    _mediaSubscription = handler.sharedMediaStream.listen((media) {
      _handleSharedMedia(media);
    }, onError: (err) {
      logger.warning('Error in sharedMediaStream: $err');
    });

    final backupIntentService = BackupImportIntentService.instance;
    backupIntentService.consumeInitialBackupPath().then((path) {
      if (path != null) {
        _handleBackupFile(path);
      }
    }).catchError((err, stack) {
      logger.warning('Error reading initial backup import intent: $err');
    });
    _backupPathSubscription = backupIntentService.backupPathStream.listen(
      (path) {
        _handleBackupFile(path);
      },
      onError: (err) {
        logger.warning('Error in backupPathStream: $err');
      },
    );
  }

  Future<void> _handleSharedMedia(SharedMedia media) async {
    if (_isHandlingShare) return;

    _isHandlingShare = true;

    try {
      final attachments = media.attachments ?? const [];
      final backupFilePath = _firstBackupFilePath(attachments);
      if (backupFilePath != null) {
        await _handleBackupFile(backupFilePath);
        return;
      }

      // Ensure model is configured before accepting shared content
      final configs = await UserStorage.getLLMConfigs();
      final hasValidConfig = configs.any((c) => c.isValid);
      if (!hasValidConfig) {
        ToastHelper.showErrorWithKey(
          scaffoldMessengerKey,
          UserStorage.l10n.modelNotConfiguredSubmitHint,
        );
        return;
      }

      final trimmedText = media.content == null || media.content!.trim().isEmpty
          ? null
          : media.content!.trim();

      final imageFiles = <XFile>[];

      for (final attachment in attachments) {
        if (attachment == null) continue;
        final path = attachment.path;
        if (path.isEmpty) continue;

        final isImageAttachment =
            attachment.type == SharedAttachmentType.image ||
                _looksLikeImageFile(path);
        if (isImageAttachment) {
          imageFiles.add(XFile(path));
        }
      }

      final inputData = SharedDraft(
        text: trimmedText,
        images: imageFiles,
      );

      if (inputData.isEmpty) return;

      onSharedDraft(inputData);
    } catch (e, stackTrace) {
      logger.severe('Error handling shared media: $e', e, stackTrace);
      ToastHelper.showErrorWithKey(scaffoldMessengerKey, e);
    } finally {
      _isHandlingShare = false;
    }
  }

  void dispose() {
    _mediaSubscription?.cancel();
    _backupPathSubscription?.cancel();
  }

  Future<void> _handleBackupFile(String rawPath) async {
    if (_isHandlingBackupFile) return;
    final backupFilePath = _normalizeFilePath(rawPath);
    if (!BackupService.isMemexBackupFile(backupFilePath)) {
      ToastHelper.showErrorWithKey(
        scaffoldMessengerKey,
        UserStorage.l10n.invalidBackupFile,
      );
      return;
    }

    _isHandlingBackupFile = true;
    try {
      await onBackupFileShared(backupFilePath);
    } catch (e, stackTrace) {
      logger.severe('Error handling backup file: $e', e, stackTrace);
      ToastHelper.showErrorWithKey(scaffoldMessengerKey, e);
    } finally {
      _isHandlingBackupFile = false;
    }
  }

  String? _firstBackupFilePath(List<SharedAttachment?> attachments) {
    for (final attachment in attachments) {
      if (attachment == null) continue;
      final path = attachment.path;
      if (path.isEmpty) continue;
      final normalizedPath = _normalizeFilePath(path);
      if (attachment.type == SharedAttachmentType.file &&
          BackupService.isMemexBackupFile(normalizedPath)) {
        return normalizedPath;
      }
    }
    return null;
  }

  String _normalizeFilePath(String filePath) {
    if (filePath.startsWith('file://')) {
      try {
        return Uri.parse(filePath).toFilePath();
      } catch (_) {
        return filePath.replaceFirst('file://', '');
      }
    }
    return filePath;
  }

  bool _looksLikeImageFile(String path) {
    final lowerPath = path.toLowerCase();
    const imageExtensions = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.heic',
      '.heif',
      '.bmp',
      '.tif',
      '.tiff',
    ];
    return imageExtensions.any(lowerPath.endsWith);
  }
}
