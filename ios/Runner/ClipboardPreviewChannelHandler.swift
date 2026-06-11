import Flutter
import UIKit

/// Handles `com.memexlab.memex/clipboard_preview` MethodChannel.
class ClipboardPreviewChannelHandler: NSObject {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.memexlab.memex/clipboard_preview",
            binaryMessenger: messenger
        )
        let instance = ClipboardPreviewChannelHandler()
        channel.setMethodCallHandler(instance.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getClipboardSummary":
            getClipboardSummary(result: result)
        case "copyImageToCache":
            copyImageToCache(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getClipboardSummary(result: @escaping FlutterResult) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages {
            result([
                "type": "image",
                "mimeType": "image/png",
                "fileName": "clipboard_image.png",
                "sourceId": "ios:\(pasteboard.changeCount):image",
            ])
            return
        }

        guard let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            result(nil)
            return
        }

        result([
            "type": "text",
            "text": text,
        ])
    }

    private func copyImageToCache(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = UIPasteboard.general.image,
                  let data = image.pngData() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_IMAGE", message: "No clipboard image", details: nil))
                }
                return
            }

            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clipboard_images", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let fileURL = directory.appendingPathComponent(
                    "clipboard_image_\(Int(Date().timeIntervalSince1970 * 1000)).png"
                )
                try data.write(to: fileURL, options: .atomic)
                DispatchQueue.main.async { result(fileURL.path) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "COPY_FAILED", message: "\(error)", details: nil))
                }
            }
        }
    }
}
