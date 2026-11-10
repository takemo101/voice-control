import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 画像の背景を消す（主役だけを残して、まわりを透明にする）。Apple の Vision の前景マスク（`VNGenerateForegroundInstanceMaskRequest`。**この Mac の中だけ**で動く。言語モデルを通さない）。
/// `vc image remove-background` が使う（SPEC F51。実験）。
public enum BackgroundRemoval {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    /// 主役を残して、背景を透明にした画像。主役が見つからなければ、`Failure`。
    public static func remove(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw Failure(message: "背景を消せませんでした（\(error.localizedDescription)）") }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure(message: "切り抜く主役（人・動物・物）が、見つかりませんでした")
        }
        let masked: CVPixelBuffer
        do { masked = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false) }
        catch { throw Failure(message: "背景を消せませんでした（\(error.localizedDescription)）") }
        let output = CIImage(cvPixelBuffer: masked)
        guard let result = CIContext().createCGImage(output, from: output.extent) else { throw Failure(message: "背景を消した画像を作れませんでした") }
        return result
    }
}
