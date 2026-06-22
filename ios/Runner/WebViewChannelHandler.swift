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
        case "renderHtmlToImage":
            renderHtmlToImage(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Render HTML to image (off-screen)

    private func renderHtmlToImage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "renderHtmlToImage requires a 'html' string argument.",
                details: nil
            ))
            return
        }
        let width = (args["width"] as? NSNumber)?.doubleValue ?? 390
        let maxHeight = (args["maxHeight"] as? NSNumber)?.doubleValue ?? 3000

        // The renderer owns a self-contained off-screen WKWebView and keeps a
        // strong reference to itself until the snapshot completes. It is fully
        // isolated from any timeline card WebView, so there is no ambiguity
        // about which WebView is captured.
        let renderer = OffscreenHtmlRenderer(
            width: CGFloat(width),
            maxHeight: CGFloat(maxHeight)
        )
        renderer.render(html: html) { base64 in
            if let base64 = base64 {
                result(base64)
            } else {
                result(FlutterError(
                    code: "RENDER_FAILED",
                    message: "Failed to render HTML snapshot.",
                    details: nil
                ))
            }
        }
    }

    // MARK: - Disable scrolling

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

/// Renders a self-contained HTML document into a PNG (base64) using an
/// off-screen `WKWebView`. The web engine performs the rendering, so the result
/// is reliable on both real devices and simulators (unlike Flutter-layer
/// screenshots of platform views).
private final class OffscreenHtmlRenderer: NSObject, WKNavigationDelegate {

    /// Keeps renderers alive for the duration of the async render.
    private static var active: [OffscreenHtmlRenderer] = []

    private let width: CGFloat
    private let maxHeight: CGFloat
    private var webView: WKWebView?
    private var completion: ((String?) -> Void)?
    private var finished = false

    init(width: CGFloat, maxHeight: CGFloat) {
        self.width = width
        self.maxHeight = maxHeight
        super.init()
    }

    func render(html: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        OffscreenHtmlRenderer.active.append(self)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let config = WKWebViewConfiguration()
            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: self.width, height: 1),
                configuration: config
            )
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.navigationDelegate = self
            self.webView = webView

            // Insert behind everything so it lays out/renders without being
            // visible to the user, then remove it once captured.
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.insertSubview(webView, at: 0)
            }

            webView.loadHTMLString(html, baseURL: nil)

            // Safety timeout in case navigation never finishes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.complete(with: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Measure real content height, then resize and snapshot.
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
            guard let self = self else { return }
            var height = self.maxHeight
            if let n = value as? NSNumber {
                height = min(CGFloat(n.doubleValue), self.maxHeight)
            }
            if height <= 0 { height = 1 }
            webView.frame = CGRect(x: 0, y: 0, width: self.width, height: height)

            // Let layout settle (images/fonts) before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.takeSnapshot()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(with: nil)
    }

    private func takeSnapshot() {
        guard let webView = webView else {
            complete(with: nil)
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.frame.size)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self = self else { return }
            guard let image = image, let data = image.pngData() else {
                self.complete(with: nil)
                return
            }
            self.complete(with: data.base64EncodedString())
        }
    }

    private func complete(with base64: String?) {
        if finished { return }
        finished = true
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        let cb = completion
        completion = nil
        cb?(base64)
        OffscreenHtmlRenderer.active.removeAll { $0 === self }
    }
}
