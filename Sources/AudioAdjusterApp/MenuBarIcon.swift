import AppKit
import BrandMark

enum MenuBarIcon {

    /// The mark at the usual 18pt menu bar glyph size, in the reduced form — three tracks
    /// and three fills would be indistinguishable this small.
    ///
    /// Drawn flat black and marked as a template, which hands macOS the light menu bar,
    /// the dark menu bar and the highlighted state; nothing here picks a colour.
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ink = CGColor(gray: 0, alpha: 1)
            BrandMark.draw(in: context, rect: rect, form: .reduced, color: ink, trackColor: ink)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Audio Adjuster"
        return image
    }()
}
