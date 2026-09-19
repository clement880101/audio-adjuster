import AppKit
import SwiftUI

@main
struct AudioAdjusterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // MenuBarGlyphTemplate.png is generated into the bundle by `make icon`. The
        // "Template" suffix is load bearing: NSImage(named:) reads it and sets isTemplate,
        // which is what lets macOS invert the glyph for a light or dark menu bar — so
        // nothing here picks a colour.
        MenuBarExtra("Audio Adjuster", image: "MenuBarGlyphTemplate") {
            MenuBarContentView(model: model)
                // The polling loop already runs; this just avoids showing a list up to a
                // second stale at the moment the popover opens.
                .onAppear { model.refreshNow() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Started here rather than from a view's onAppear: the app must be watching for
        // audio from launch, not from the first time the user opens the popover.
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// Restores every tapped app before we exit. Quitting while a tap is running would
    /// otherwise leave that app muted.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutDown() }
    }
}
