import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AssistedRunLogic

/// A saved screenshot that came out almost black (the page's transparent background saved as black) is brightened until the page shows; a normal one is left
/// alone. (That a screenshot is taken, saved and shown, not blank, is the "did not confirm in time" journey in FixtureJourneyUITests.)
final class EvidencePictureTests: XCTestCase {
    private func jpeg(gray: CGFloat) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: gray, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testAnAlmostBlackScreenshotIsBrightenedAndANormalOneIsLeftAlone() throws {
        let dark = try XCTUnwrap(EvidencePicture.cgImage(from: jpeg(gray: 5.0 / 255)))
        XCTAssertLessThan(EvidencePicture.mean(of: dark), 0.03)
        XCTAssertGreaterThan(EvidencePicture.mean(of: EvidencePicture.shown(dark)), 0.3, "the page shows again")
        let normal = try XCTUnwrap(EvidencePicture.cgImage(from: jpeg(gray: 1)))
        XCTAssertGreaterThan(EvidencePicture.mean(of: EvidencePicture.shown(normal)), 0.8)
        XCTAssertNil(EvidencePicture.cgImage(from: Data("not a picture".utf8)))
    }
}
