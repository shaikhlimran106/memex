import Flutter
import UIKit
import WebKit

/// Handles `com.memexlab.memex/webview` MethodChannel.
class WebViewChannelHandler: NSObject {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.memexlab.memex/webview",
            binaryMessenger: messenger
        )
        let instance = WebViewChannelHandler()
        channel.setMethodCallHandler(instance.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "disableScrolling":
            disableWebViewScrolling()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Private

    private func disableWebViewScrolling() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        disableScrollingInView(window)
    }

    private func disableScrollingInView(_ view: UIView) {
        if let webView = view as? WKWebView {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.showsHorizontalScrollIndicator = false
            webView.scrollView.bounces = false
            webView.scrollView.alwaysBounceVertical = false
            webView.scrollView.alwaysBounceHorizontal = false
        }
        for subview in view.subviews {
            disableScrollingInView(subview)
        }
    }
}
