import UIKit

/// Turns saved screenshot data into an image for the review screens (the picture work is `EvidencePicture`, tested on the Mac).
enum EvidenceImage {
    static func image(from data: Data) -> UIImage? {
        guard let cg = EvidencePicture.cgImage(from: data) else { return UIImage(data: data) }
        return UIImage(cgImage: EvidencePicture.shown(cg))
    }
}
