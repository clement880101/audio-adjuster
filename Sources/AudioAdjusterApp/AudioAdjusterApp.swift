import AppKit
import SwiftUI

@main
struct AudioAdjusterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Audio Adjuster", systemImage: "slider.horizontal.3") {
            MenuBarContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Guarantees every tapped app is restored when the app quits. Without this, quitting
/// while a tap is running would leave that app muted.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { Task { @MainActor in model?.start() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutDown() }
    }
}
