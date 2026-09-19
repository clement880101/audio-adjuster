import CoreGraphics

/// The Audio Adjuster mark: three stacked level bars, one per app.
///
/// The same geometry is written out by hand as inline SVG in `site/index.html` — six
/// rectangles were not worth a build step that generates the site from this file. Change
/// one and change the other.
public enum BrandMarkForm {
    /// Tracks and fills. Legible from 64px up.
    case full
    /// Fills only, thickened into the space the tracks leave behind. Below 64px three
    /// tracks and three fills smear into one grey block, so small sizes drop the tracks.
    case reduced
}

public struct BrandMarkBar {
    public let rect: CGRect
    public let isTrack: Bool
}

public enum BrandMark {

    /// Fills as a fraction of the track: 62%, 83%, 38%. Middle bar longest, matching the
    /// levels already drawn on the social card.
    private static let fillWidths: [CGFloat] = [52, 70, 32]

    /// Laid out in a 100×100 box with y measured from the top, then flipped — these are
    /// the numbers in the design doc and in the site's SVG, and they should stay readable
    /// against both.
    private static func layout(form: BrandMarkForm) -> (rows: [CGFloat], height: CGFloat) {
        switch form {
        case .full:    return ([16, 42, 68], 16)
        case .reduced: return ([12, 40, 68], 20)
        }
    }

    /// The bars that make up the mark, scaled to fill `rect` and centred in it.
    ///
    /// Tracks come first, so drawing the list in order paints every fill over its track.
    public static func bars(form: BrandMarkForm, in rect: CGRect) -> [BrandMarkBar] {
        let scale = min(rect.width, rect.height) / 100
        let originX = rect.minX + (rect.width - 100 * scale) / 2
        let originY = rect.minY + (rect.height - 100 * scale) / 2
        let (rows, height) = layout(form: form)

        // y arrives measured from the top of the box; Core Graphics wants it from the
        // bottom, so the first row ends up highest.
        func bar(x: CGFloat, yFromTop: CGFloat, width: CGFloat, isTrack: Bool) -> BrandMarkBar {
            BrandMarkBar(
                rect: CGRect(x: originX + x * scale,
                             y: originY + (100 - yFromTop - height) * scale,
                             width: width * scale,
                             height: height * scale),
                isTrack: isTrack
            )
        }

        var result: [BrandMarkBar] = []
        if form == .full {
            result += rows.map { bar(x: 8, yFromTop: $0, width: 84, isTrack: true) }
        }
        result += zip(rows, fillWidths).map { bar(x: 8, yFromTop: $0, width: $1, isTrack: false) }
        return result
    }

    /// Draws the mark scaled to fill `rect`. `trackColor` is unused by the reduced form,
    /// which has no tracks.
    public static func draw(in context: CGContext, rect: CGRect, form: BrandMarkForm,
                            color: CGColor, trackColor: CGColor) {
        for bar in bars(form: form, in: rect) {
            // Every bar is a pill: the radius is half the height, so the shortest fill
            // still ends in a proper round cap rather than a clipped corner.
            let radius = bar.rect.height / 2
            context.setFillColor(bar.isTrack ? trackColor : color)
            context.addPath(CGPath(roundedRect: bar.rect,
                                   cornerWidth: radius, cornerHeight: radius,
                                   transform: nil))
            context.fillPath()
        }
    }

    // MARK: - Application icon

    /// Proportions of the macOS application-icon canvas, as fractions of the full square:
    /// an 824×824 rounded square with an 185.4 corner radius, inset in 1024.
    private static let canvasInset: CGFloat = 100 / 1024
    private static let canvasCornerRadius: CGFloat = 185.4 / 1024
    private static let markWidth: CGFloat = 600 / 1024

    /// Draws the icon as macOS expects it: the mark on its own rounded canvas, filling a
    /// `size`×`size` context.
    public static func drawAppIcon(in context: CGContext, size: CGFloat) {
        let inset = canvasInset * size
        let canvas = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let radius = canvasCornerRadius * size

        context.saveGState()
        context.addPath(CGPath(roundedRect: canvas, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        // Barely a gradient — enough to keep the tile from reading as a flat sticker at
        // 1024, invisible by the time it is 32.
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [CGColor(colorSpace: space, components: [0.102, 0.114, 0.125, 1])!,
                                           CGColor(colorSpace: space, components: [0.059, 0.067, 0.075, 1])!] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: canvas.maxY),
                                   end: CGPoint(x: 0, y: canvas.minY),
                                   options: [])
        context.restoreGState()

        // Below 64px the tracks are sub-pixel and only muddy the fills.
        let form: BrandMarkForm = size < 64 ? .reduced : .full
        let markSide = markWidth * size
        let markRect = CGRect(x: (size - markSide) / 2, y: (size - markSide) / 2,
                              width: markSide, height: markSide)
        draw(in: context, rect: markRect, form: form,
             color: CGColor(colorSpace: space, components: [0.949, 0.639, 0.235, 1])!,
             trackColor: CGColor(colorSpace: space, components: [0.133, 0.149, 0.165, 1])!)
    }
}
