//
//  GoDarkApp.swift
//  GoDark
//
//  Created by Dina Basumatary on 21/10/2026.
//

import SwiftUI
import AppKit

@main
struct GoDarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single, non-duplicable window. The window is only a controller:
        // display changes are applied to the system, not tied to this window's lifetime.
        Window("GoDark", id: "main") {
            ContentView()
                .environment(appDelegate.displays)
                // A small utility panel: no full screen, and grow downward as displays come and go.
                .windowFullScreenBehavior(.disabled)
                .windowResizeAnchor(.top)
        }
        // The window tracks the content's fixed size, so it can't be stretched or zoomed into empty space.
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so the display watcher outlives the window.
    let displays = DisplayManager()

    /// Keep running after the window closes, so the built-in display can still be restored
    /// if the last external monitor is unplugged.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Once the app is gone nothing can turn the built-in display back on, so restore it now.
    func applicationWillTerminate(_ notification: Notification) {
        displays.restoreBuiltInDisplay()
    }
}
