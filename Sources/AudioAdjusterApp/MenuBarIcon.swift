import AppKit

enum MenuBarIcon {

    /// The menu bar glyph, generated into the bundle by `make icon`.
    ///
    /// Loaded with `NSImage(named:)` rather than handed to SwiftUI as `Image("name")`:
    /// SwiftUI's string lookup only finds images in a compiled asset catalog, and this
    /// bundle has none, so that path silently produced a status item with no image at all
    /// — a clickable but entirely blank slot in the menu bar.
    ///
    /// The "Template" suffix on the file name is load bearing: `NSImage(named:)` reads it
    /// and sets `isTemplate`, which is what lets macOS invert the glyph for a light or
    /// dark menu bar. Nothing here picks a colour.
    static let image: NSImage = {
        guard let image = NSImage(named: "MenuBarGlyphTemplate") else {
            // Better a visible fallback than an invisible menu bar item.
            return NSImage(systemSymbolName: "slider.horizontal.3",
                           accessibilityDescription: "Audio Adjuster")
                ?? NSImage(size: NSSize(width: 18, height: 18))
        }
        image.accessibilityDescription = "Audio Adjuster"
        return image
    }()
}
