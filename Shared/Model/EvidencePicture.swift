import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// The picture side of a saved screenshot, without UIKit (so it is tested on the Mac): read the saved data, tell how bright it is, and brighten one that came out
/// almost black. The first screenshots were saved with the page's transparent background turned black, which leaves the page almost invisible; a picture that
/// dark is brightened until the page shows again; new screenshots are saved on white and are left alone. The app wraps it in `EvidenceImage` (UIImage).
enum EvidencePicture {
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The picture as it should be shown: brightened when it is almost black, else as it is.
    static func shown(_ image: CGImage) -> CGImage {
        guard mean(of: image) < 0.03 else { return image }
        let scale: CGFloat = 45
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
        // No colour management, so the multiplication is applied to the stored values, not to linearised ones.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let out = filter.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return image }
        return cg
    }

    /// Average brightness, 0 (black) to 1 (white), from a tiny copy of the picture.
    static func mean(of image: CGImage) -> Double {
        let w = 16, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return Double(sum) / Double(w * h * 3 * 255)
    }
}
