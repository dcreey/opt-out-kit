import UIKit
import CoreImage

/// Turns saved screenshot data into an image for the review screens.
enum EvidenceImage {
    /// The first screenshots were saved with the page's transparent background turned black, which leaves the page almost invisible.
    /// A picture that dark is brightened until the page shows again; new screenshots are saved on white and are left alone.
    static func image(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        guard mean(of: image) < 0.03, let input = CIImage(image: image) else { return image }
        let scale: CGFloat = 45
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
        // No colour management, so the multiplication is applied to the stored values, not to linearised ones.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let out = filter.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Average brightness, 0 (black) to 1 (white), from a tiny copy of the picture.
    static func mean(of image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 1 }
        let w = 16, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return Double(sum) / Double(w * h * 3 * 255)
    }
}
