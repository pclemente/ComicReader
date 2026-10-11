import UIKit
import XCTest
@testable import ComicFlow

@MainActor
final class CRReaderImageFiltersTests: XCTestCase {
    func testPresetsPreserveGeometryAndOriginalPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let original = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32), format: format).image { context in
            // Mid-tone colors make the contrast preset observable. Fully saturated
            // red/blue can clip back to the same channel values after contrast.
            UIColor(red: 0.24, green: 0.43, blue: 0.68, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 32))
            UIColor(red: 0.72, green: 0.46, blue: 0.21, alpha: 1).setFill()
            context.fill(CGRect(x: 12, y: 0, width: 12, height: 32))
        }
        let originalBytes = try XCTUnwrap(original.pngData())
        XCTAssertTrue(CRReaderImageFilters.render(original, preset: 0) === original)
        XCTAssertTrue(CRReaderImageFilters.render(original, preset: 99) === original)
        for preset in 1...3 {
            let filtered = CRReaderImageFilters.render(original, preset: preset)
            XCTAssertEqual(filtered.size, original.size)
            XCTAssertEqual(filtered.scale, original.scale)
            XCTAssertEqual(filtered.imageOrientation, original.imageOrientation)
            XCTAssertNotEqual(filtered.pngData(), originalBytes)
        }
        XCTAssertEqual(original.pngData(), originalBytes)
    }

    func testGrayscaleHasEqualColorChannels() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let filtered = try XCTUnwrap(CRReaderImageFilters.render(image, preset: 2).cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(filtered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThanOrEqual(abs(Int(pixel[0]) - Int(pixel[1])), 1)
        XCTAssertLessThanOrEqual(abs(Int(pixel[1]) - Int(pixel[2])), 1)
    }
}
