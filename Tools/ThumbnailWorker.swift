import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Short-lived process: decoder and GPU surfaces are reclaimed when this worker exits.
@main struct ThumbnailWorker {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let result: Data? = autoreleasepool {
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 480, height: 320)
            generator.appliesPreferredTrackTransform = true
            defer { generator.cancelAllCGImageGeneration() }
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else { return nil }
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(output), data.length <= 524288 else { return nil }
            return data as Data
        }
        guard let result else { exit(1) }
        do { try FileHandle.standardOutput.write(contentsOf: result) } catch { exit(1) }
    }
}
