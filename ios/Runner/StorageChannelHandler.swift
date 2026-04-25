import Flutter
import Foundation

/// Handles `com.memexlab.memex/storage` MethodChannel.
class StorageChannelHandler: NSObject {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.memexlab.memex/storage",
            binaryMessenger: messenger
        )
        let instance = StorageChannelHandler()
        channel.setMethodCallHandler(instance.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getICloudContainerPath":
            getICloudContainerPath(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Private

    private func getICloudContainerPath(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let explicitContainer = "iCloud.com.memexlab.memex"
            var url = FileManager.default.url(forUbiquityContainerIdentifier: explicitContainer)
            if url == nil {
                url = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            }
            DispatchQueue.main.async {
                if let url = url {
                    NSLog("[iCloud] container path resolved: \(url.path)")
                    result(url.path)
                } else {
                    let hasIdentity = FileManager.default.ubiquityIdentityToken != nil
                    NSLog("[iCloud] container path is nil. ubiquityIdentityToken exists: \(hasIdentity)")
                    result(nil)
                }
            }
        }
    }
}
