import CoreGraphics
import Testing
@testable import BrandMark

@Suite("BrandMark")
struct BrandMarkGeometryTests {

    /// Every size the mark is actually asked for, plus one absurd one.
    private static let sizes: [CGFloat] = [16, 18, 32, 64, 128, 1024]

    @Test("every bar stays inside the rect it was asked to fill")
    func barsStayInsideTheirRect() {
        for form in [BrandMarkForm.full, .reduced] {
            for size in Self.sizes {
                // An offset origin too: a mark drawn into a corner of a larger canvas
                // must not be laid out as though the canvas started at zero.
                for origin in [CGPoint.zero, CGPoint(x: 37, y: 11)] {
                    let rect = CGRect(x: origin.x, y: origin.y, width: size, height: size)
                    let bars = BrandMark.bars(form: form, in: rect)
                    #expect(!bars.isEmpty)
                    for bar in bars {
                        #expect(rect.contains(bar.rect),
                                "\(form) at \(size) from \(origin): \(bar.rect) escapes \(rect)")
                    }
                }
            }
        }
    }

    @Test("the full form draws a track and a fill per row, the reduced form only fills")
    func formsHaveTheRightBarCounts() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let full = BrandMark.bars(form: .full, in: rect)
        #expect(full.count == 6)
        #expect(full.filter(\.isTrack).count == 3)
        #expect(BrandMark.bars(form: .reduced, in: rect).allSatisfy { !$0.isTrack })
        #expect(BrandMark.bars(form: .reduced, in: rect).count == 3)
    }

    @Test("the three fills keep their relative widths at every size")
    func fillWidthsKeepTheirProportions() throws {
        for form in [BrandMarkForm.full, .reduced] {
            for size in Self.sizes {
                let rect = CGRect(x: 0, y: 0, width: size, height: size)
                let fills = BrandMark.bars(form: form, in: rect).filter { !$0.isTrack }
                try #require(fills.count == 3)
                // 62%, 95%, 38% of the 84-wide track, middle bar longest.
                #expect(fills[1].rect.width > fills[0].rect.width)
                #expect(fills[0].rect.width > fills[2].rect.width)
            }
        }
    }
}

@Suite("BrandMark rendering")
struct BrandMarkRenderingTests {

    /// Renders the mark white-on-transparent and returns the alpha of each pixel.
    private func alphaMap(form: BrandMarkForm, size: Int) -> [UInt8] {
        let bytesPerRow = size
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress,
                                    width: size, height: size,
                                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let white = CGColor(gray: 1, alpha: 1)
            BrandMark.draw(in: context,
                           rect: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)),
                           form: form, color: white, trackColor: white)
        }
        return pixels
    }

    @Test("drawing puts ink on the canvas")
    func drawingIsNotBlank() {
        for form in [BrandMarkForm.full, .reduced] {
            let pixels = alphaMap(form: form, size: 64)
            #expect(pixels.contains { $0 > 128 }, "\(form) rendered blank at 64px")
        }
    }

    /// The failure this mark is most likely to have: at menu bar and favicon size the
    /// three bars smear into one block, and the logo stops meaning "one per app".
    @Test("the reduced form still reads as three separate bars at 16px")
    func reducedFormKeepsThreeBarsAt16px() {
        let size = 16
        let pixels = alphaMap(form: .reduced, size: size)
        // Column 3 crosses all three bars: every bar starts at 8% of the width and the
        // shortest runs to 40%, so 3/16 is inside all of them.
        let column = (0..<size).map { pixels[$0 * size + 3] }
        var runs = 0
        var inRun = false
        for value in column {
            let lit = value > 128
            if lit && !inRun { runs += 1 }
            inRun = lit
        }
        #expect(runs == 3, "expected three separate bars down column 3, found \(runs)")
    }
}
