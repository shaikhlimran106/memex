import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:memex/utils/logger.dart';

/// Renders self-contained HTML into a PNG snapshot through the native
/// `com.memexlab.memex/webview` channel (`renderHtmlToImage`).
///
/// The native side creates a dedicated off-screen WebView, loads the HTML,
/// waits for it to render, and returns a base64 PNG. This is reliable across
/// iOS and Android because the capture happens inside the native WebView,
/// unlike Flutter-layer screenshots of platform views.
///
/// Used by the dynamic timeline UI skill so the agent can visually inspect the
/// HTML card it generated before saving it to the Timeline. The HTML must be
/// wrapped with `HtmlWebViewCard.buildTimelineHtmlDocument` first so the
/// snapshot matches real Timeline rendering.
class WebviewSnapshotService {
  static final WebviewSnapshotService instance = WebviewSnapshotService._();

  WebviewSnapshotService._();

  static const MethodChannel _channel =
      MethodChannel('com.memexlab.memex/webview');

  final _logger = getLogger('WebviewSnapshotService');

  /// Renders [html] (a complete, self-contained HTML document) into PNG bytes.
  ///
  /// [width] is logical width in dp (390 matches the share card width and the
  /// timeline card width). [maxHeight] clamps very tall content (3000 matches
  /// the timeline card `maxHeight`).
  ///
  /// Returns null if rendering failed or the platform does not support it.
  Future<Uint8List?> renderHtmlToImage({
    required String html,
    double width = 390,
    double maxHeight = 3000,
  }) async {
    try {
      final base64Png = await _channel.invokeMethod<String>(
        'renderHtmlToImage',
        {
          'html': html,
          'width': width,
          'maxHeight': maxHeight,
        },
      );
      if (base64Png == null || base64Png.isEmpty) {
        _logger.warning('renderHtmlToImage returned empty result.');
        return null;
      }
      return base64Decode(base64Png);
    } on MissingPluginException catch (e) {
      _logger.warning('renderHtmlToImage not available on this platform: $e');
      return null;
    } on PlatformException catch (e) {
      _logger.warning('renderHtmlToImage failed: ${e.code} ${e.message}');
      return null;
    } catch (e) {
      _logger.severe('renderHtmlToImage unexpected error: $e');
      return null;
    }
  }
}
