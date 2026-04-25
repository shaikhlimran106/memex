import Flutter
import AVFoundation

/// Handles `com.memexlab.memex/audio_converter` MethodChannel.
///
/// Audio conversion logic (WAV encoding, PCM extraction) is kept in this file
/// since it's tightly coupled to the channel's single method. If the service
/// grows (e.g. multiple formats), extract to a separate AudioConverterService.
class AudioConverterChannelHandler: NSObject {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.memexlab.memex/audio_converter",
            binaryMessenger: messenger
        )
        let instance = AudioConverterChannelHandler()
        channel.setMethodCallHandler(instance.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "convertToWav":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Missing inputPath or outputPath", details: nil))
                return
            }
            Self.convertToWav(inputPath: inputPath, outputPath: outputPath, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Audio Conversion

    /// Convert audio to WAV 16kHz mono using AVFoundation
    private static func convertToWav(inputPath: String, outputPath: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let inputURL = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath)

            try? FileManager.default.removeItem(at: outputURL)

            let asset = AVURLAsset(url: inputURL)
            guard let track = asset.tracks(withMediaType: .audio).first else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "READ_ERROR", message: "No audio track found", details: nil))
                }
                return
            }

            guard let reader = try? AVAssetReader(asset: asset) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "READ_ERROR", message: "Cannot create asset reader", details: nil))
                }
                return
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]

            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(readerOutput)

            guard reader.startReading() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "READ_ERROR",
                                        message: "Cannot start reading: \(reader.error?.localizedDescription ?? "unknown")",
                                        details: nil))
                }
                return
            }

            var pcmData = Data()
            while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    var data = Data(count: length)
                    data.withUnsafeMutableBytes { ptr in
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                   dataLength: length,
                                                   destination: ptr.baseAddress!)
                    }
                    pcmData.append(data)
                }
            }

            guard reader.status == .completed else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "READ_ERROR",
                                        message: "Reading failed: \(reader.error?.localizedDescription ?? "unknown")",
                                        details: nil))
                }
                return
            }

            // Build WAV: header + PCM data
            let wavData = buildWav(pcmData: pcmData, sampleRate: 16000)

            do {
                try wavData.write(to: outputURL)
                DispatchQueue.main.async { result(outputPath) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "WRITE_ERROR",
                                        message: "Cannot write WAV: \(error)", details: nil))
                }
            }
        }
    }

    private static func buildWav(pcmData: Data, sampleRate: UInt32) -> Data {
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + dataSize)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Array($0) }) // byte rate
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var wav = header
        wav.append(pcmData)
        return wav
    }
}
