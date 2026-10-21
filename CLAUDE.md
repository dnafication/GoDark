# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

GoDark is a small macOS SwiftUI app that turns individual displays (built-in and external) on and off, e.g. to blank the MacBook's built-in screen while using an external monitor.

## Commands

- Build: `xcodebuild -project GoDark.xcodeproj -scheme GoDark build` (or the Xcode `BuildProject` tool)
- There is no test target yet.
- Read the app's logs (after reproducing an issue):
  `log show --last 10m --info --predicate 'subsystem == "com.dnafication.GoDark"'`

## Architecture

Everything lives in two files:

- `GoDark/ContentView.swift`: the private CoreGraphics declarations, the `DisplayManager` model and the SwiftUI views.
- `GoDark/GoDarkApp.swift`: the app's scene setup and its `AppDelegate`.

### Private API

Displays are enabled or disabled with `CGSConfigureDisplayEnabled`, and disabled displays are listed with `CGSGetDisplayList`. Both are private CoreGraphics symbols bound through `@_silgen_name`. Because of this the app can't go on the Mac App Store. Changes are applied with `.forSession`, so a log out or restart turns every display back on.

### Display lists

Disabled displays are missing from the public lists, so `DisplayManager.displayIDs(_:)` combines two:

| List | Source | Contains |
| --- | --- | --- |
| `.active` | `CGGetActiveDisplayList` | Enabled displays |
| `.all` | `CGSGetDisplayList` (private) | Enabled and disabled displays |

Disabling a display through this API looks to WindowServer like unplugging it (a hotplug "out").

`.all` also keeps reporting displays that were unplugged, and the placeholder macOS adds when the last monitor goes. CoreGraphics can't tell these apart from disabled displays (both are offline with 1×1 bounds). So an inactive external display is listed only if IOKit says it is physically attached: `attachedMonitors()` reads the `DisplayAttributes` of each `IOMobileFramebufferShim` (Apple silicon), which stay present while a connected display is disabled, and matches vendor, model and serial against CoreGraphics. Where there are no such framebuffers (Intel), any inactive display with a vendor number is listed. The built-in display is always listed.

A display that is still disabled for the session stays disabled when it's unplugged and plugged back in, and neither plugging it in nor unplugging it produces a reconfiguration event. So `refresh()` also runs on `NSApplication.didBecomeActiveNotification`, and a task polls `attachedMonitors()` every 2 seconds and refreshes when the result changes.

Disabled displays also disappear from `NSScreen`, so display names are cached in `UserDefaults` (`knownDisplayNames`). Rows are sorted built-in first, then by ID, because macOS reorders IDs and changes names after a reconfiguration.

### Built-in display safety net

This part matters most. If the built-in display is off when the last external monitor is unplugged, the user is left with no screen. Several pieces together prevent that:

- `restoreBuiltInIfStranded()` runs on every `refresh()`. When it first sees the built-in display off, it records the active external displays (`externalsWhileBuiltInOff`). Once none of those is still active, it turns the built-in display back on.
- Don't replace this with an "is any display active/online" check. When the last real monitor is unplugged, macOS inserts an **active placeholder display** (it was seen as a 1920×1080 display with a new ID), so the Mac never looks screenless. The placeholder is removed when a real monitor returns.
- `refresh()` is triggered by a `CGDisplayRegisterReconfigurationCallback` (reliable on unplug) and by `NSApplication.didChangeScreenParametersNotification`.
- While the built-in display is off, a polling watchdog calls `refresh()` every 2 seconds. A `ProcessInfo` activity stops App Nap from throttling it.
- `builtInID` is remembered in case the built-in display drops out of every list.
- `setEnabled` refuses to turn off the last active display.

### App lifecycle

There is a single `Window` scene, which can't be duplicated. `AppDelegate` owns the `DisplayManager` so it outlives the window. Closing the window doesn't quit the app (`applicationShouldTerminateAfterLastWindowClosed` returns `false`), which keeps the safety net running. On quit, `applicationWillTerminate` turns the built-in display back on.

The window sizes itself to its content (`.windowResizability(.contentSize)` with a fixed-width, `fixedSize` grouped `Form`). Full screen is disabled, and the window grows downward from its top edge (`.windowResizeAnchor(.top)`).

## Build settings to be aware of

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: types are MainActor-isolated by default. The C display-reconfiguration callback hops back with `Task { @MainActor in ... }`, and `DisplayManager.log` is `nonisolated`.
- Swift language mode 5, with approachable concurrency.
- macOS deployment target 26.6. App Sandbox and Hardened Runtime are enabled.

## Testing caveats

Display behavior can only be verified on real hardware (toggling displays, plugging and unplugging monitors). The SwiftUI preview uses a live `DisplayManager`, so it shows the real displays on this Mac.
