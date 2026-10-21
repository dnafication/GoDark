//
//  ContentView.swift
//  GoDark
//
//  Created by Dina Basumatary on 21/10/2026.
//

import SwiftUI
import AppKit
import CoreGraphics
import IOKit
import os

// MARK: - Private CoreGraphics API

/// `CGSConfigureDisplayEnabled` is exported by CoreGraphics but not declared in any public header.
/// It is the only way to enable/disable a display from a `CGDisplayConfigRef`.
/// Because it is private API, this app is not suitable for the Mac App Store.
@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef?,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

/// Like `CGGetActiveDisplayList`, but also returns displays that have been disabled.
@_silgen_name("CGSGetDisplayList")
private func CGSGetDisplayList(
    _ maxDisplays: UInt32,
    _ displays: UnsafeMutablePointer<CGDirectDisplayID>?,
    _ count: UnsafeMutablePointer<UInt32>
) -> CGError

// MARK: - Model

struct ManagedDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var isEnabled: Bool
}

enum DisplayError: LocalizedError {
    case lastActiveDisplay
    case coreGraphics(CGError)

    var errorDescription: String? {
        switch self {
        case .lastActiveDisplay:
            "You can't turn off the only active display."
        case .coreGraphics(let error):
            "CoreGraphics failed with error code \(error.rawValue)."
        }
    }
}

@Observable
final class DisplayManager {
    private(set) var displays: [ManagedDisplay] = []
    var errorMessage: String?

    /// Disabled displays disappear from `NSScreen`, so remember the names we've seen.
    /// Persisted so a display that is already off at launch still gets its real name.
    private var knownNames: [CGDirectDisplayID: String] = [:] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: knownNames.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(stored, forKey: Self.knownNamesKey)
        }
    }

    private static let knownNamesKey = "knownDisplayNames"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.knownNamesKey) as? [String: String] ?? [:]
        knownNames = Dictionary(uniqueKeysWithValues: stored.compactMap { key, name in
            CGDirectDisplayID(key).map { ($0, name) }
        })
        refresh()

        // NSScreen notifications aren't reliable once no screen is left, so also listen at the
        // CoreGraphics level, which reports every hot-unplug. The manager lives for the whole app,
        // so an unretained reference is safe.
        let callbackResult = CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            DisplayManager.log.info("Reconfigured display \(display, privacy: .public), flags \(flags.rawValue, privacy: .public)")
            let address = Int(bitPattern: userInfo)
            Task { @MainActor in
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<DisplayManager>.fromOpaque(pointer).takeUnretainedValue().refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        if callbackResult != .success {
            Self.log.error("Couldn't register reconfiguration callback: \(callbackResult.rawValue, privacy: .public)")
            errorMessage = DisplayError.coreGraphics(callbackResult).localizedDescription
        }

        Task { [weak self] in
            // Fires on hot-plug and after our own reconfigurations.
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            ) {
                self?.refresh()
            }
        }

        Task { [weak self] in
            // Plugging in or unplugging a display that is disabled produces no reconfiguration event,
            // so also check whenever GoDark is brought to the front...
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                self?.refresh()
            }
        }

        Task { [weak self] in
            // ...and poll IOKit, which is cheap, refreshing when the attached monitors change.
            var attached = Self.attachedMonitors()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let current = Self.attachedMonitors()
                guard current != attached else { continue }
                attached = current
                Self.log.info("Attached monitors changed: \(current?.count ?? -1, privacy: .public) attached")
                refresh()
            }
        }
    }

    // MARK: Detection

    nonisolated static let log = Logger(subsystem: "com.dnafication.GoDark", category: "displays")

    /// Remembered in case the built-in display drops out of every list while it is disabled.
    private var builtInID: CGDirectDisplayID?

    /// Polls while the built-in display is off, in case a change notification is missed.
    private var watchdogTask: Task<Void, Never>?
    /// Keeps App Nap from throttling the watchdog while the window is hidden.
    private var watchdogActivity: NSObjectProtocol?

    func refresh() {
        restoreBuiltInIfStranded()

        // macOS omits disabled displays from the public active and online lists.
        // `CGSGetDisplayList` still reports them, so use it to find displays that can be switched back on.
        let active = Set(Self.displayIDs(.active))
        updateWatchdog(builtInIsOff: builtInID.map { !active.contains($0) } ?? false)

        // `CGSGetDisplayList` also keeps reporting displays that were unplugged, and the placeholder
        // macOS adds when the last monitor goes. CoreGraphics can't tell those from disabled displays,
        // so only list an inactive display if IOKit says it is still physically attached.
        let attached = Self.attachedMonitors()
        displays = Self.displayIDs(.all)
            .filter { id in
                active.contains(id) || CGDisplayIsBuiltin(id) != 0
                    || attached?.contains { $0.matches(id) } ?? (CGDisplayVendorNumber(id) != 0)
            }
            .map { id in
                let isBuiltIn = CGDisplayIsBuiltin(id) != 0
                if let name = Self.screenName(for: id), !name.isEmpty, knownNames[id] != name { knownNames[id] = name }
                return ManagedDisplay(
                    id: id,
                    name: knownNames[id] ?? (isBuiltIn ? "Built-in Display" : "External Display \(id)"),
                    isBuiltIn: isBuiltIn,
                    isEnabled: active.contains(id)
                )
            }
            // A fixed order: macOS returns IDs in varying order after a reconfiguration, and names
            // change when a display is toggled, so neither can be used to keep rows from jumping.
            .sorted { ($0.isBuiltIn ? 0 : 1, $0.id) < ($1.isBuiltIn ? 0 : 1, $1.id) }
    }

    /// The external displays that were active when the built-in display was turned off.
    /// `nil` while the built-in display is on.
    private var externalsWhileBuiltInOff: Set<CGDirectDisplayID>?

    /// Safety net: if the built-in display is off and every external display that was active
    /// when it was turned off has gone (e.g. the last monitor was unplugged), turn it back on.
    ///
    /// This can't simply check whether any display is still active or online: when the last real
    /// monitor goes away, macOS inserts an active placeholder display (seen as a 1920×1080 display
    /// with a new ID), so the Mac never looks screenless.
    private func restoreBuiltInIfStranded() {
        if let id = Self.displayIDs(.all).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            builtInID = id
        }
        guard let builtIn = builtInID else { return }

        let active = Set(Self.displayIDs(.active))
        guard !active.contains(builtIn) else {
            externalsWhileBuiltInOff = nil
            return
        }

        guard let externals = externalsWhileBuiltInOff else {
            // First time we see the built-in display off: remember which monitors are in use.
            externalsWhileBuiltInOff = active
            Self.log.notice("Built-in display \(builtIn, privacy: .public) is off; watching displays \(active.sorted(), privacy: .public)")
            if active.isEmpty { enableBuiltInDisplay(builtIn) }
            return
        }

        let remaining = externals.intersection(active)
        guard remaining.isEmpty else { return }

        Self.log.notice("Displays \(externals.sorted(), privacy: .public) are gone (active: \(active.sorted(), privacy: .public)); turning built-in display \(builtIn, privacy: .public) back on")
        enableBuiltInDisplay(builtIn)
    }

    /// Runs `refresh()` every couple of seconds while the built-in display is off.
    private func updateWatchdog(builtInIsOff: Bool) {
        if builtInIsOff, watchdogTask == nil {
            watchdogActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Turning the built-in display back on if the last external display is unplugged"
            )
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.refresh()
                }
            }
        } else if !builtInIsOff, let task = watchdogTask {
            task.cancel()
            watchdogTask = nil
            if let activity = watchdogActivity {
                ProcessInfo.processInfo.endActivity(activity)
                watchdogActivity = nil
            }
        }
    }

    private enum DisplayList {
        case active  // Enabled displays only (public API).
        case all     // Enabled and disabled displays (private API).
    }

    private static func displayIDs(_ list: DisplayList) -> [CGDirectDisplayID] {
        func query(_ max: UInt32, _ ids: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>) -> CGError {
            switch list {
            case .active: CGGetActiveDisplayList(max, ids, count)
            case .all: CGSGetDisplayList(max, ids, count)
            }
        }

        var count: UInt32 = 0
        guard query(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard query(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private struct AttachedMonitor: Equatable, CustomStringConvertible {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32

        var description: String { "\(vendor)/\(model)/\(serial)" }

        func matches(_ id: CGDirectDisplayID) -> Bool {
            let idSerial = CGDisplaySerialNumber(id)
            return vendor == CGDisplayVendorNumber(id) && model == CGDisplayModelNumber(id)
                && (serial == 0 || idSerial == 0 || serial == idSerial)
        }
    }

    /// Monitors physically attached to the Mac's display ports, whether or not they are enabled,
    /// read from the `DisplayAttributes` IOKit publishes for each Apple silicon framebuffer.
    /// `nil` if there are no such framebuffers to read (e.g. on an Intel Mac).
    private static func attachedMonitors() -> [AttachedMonitor]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var foundFramebuffer = false
        var monitors: [AttachedMonitor] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            foundFramebuffer = true
            guard
                let attributes = IORegistryEntryCreateCFProperty(
                    service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any],
                let product = attributes["ProductAttributes"] as? [String: Any]
            else { continue }
            func number(_ key: String) -> UInt32 { (product[key] as? NSNumber)?.uint32Value ?? 0 }
            monitors.append(AttachedMonitor(
                vendor: number("LegacyManufacturerID"),
                model: number("ProductID"),
                serial: number("SerialNumber")
            ))
        }
        return foundFramebuffer ? monitors : nil
    }

    private static func screenName(for id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }

    // MARK: Toggle

    func setEnabled(_ enabled: Bool, for display: ManagedDisplay) {
        errorMessage = nil
        defer { refresh() }

        // Never leave the Mac with no active display.
        if !enabled, Self.displayIDs(.active).filter({ $0 != display.id }).isEmpty {
            errorMessage = DisplayError.lastActiveDisplay.localizedDescription
            return
        }

        if let error = Self.apply(enabled: enabled, to: display.id) {
            errorMessage = error.localizedDescription
        }
    }

    /// Turns the built-in display back on if it is off. Used when no other display is active,
    /// and when the app quits so the Mac is never left without a screen and nothing to fix it.
    func restoreBuiltInDisplay() {
        let builtIn = Self.displayIDs(.all).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? builtInID
        guard let builtIn, !Self.displayIDs(.active).contains(builtIn) else { return }
        Self.log.notice("Turning built-in display \(builtIn, privacy: .public) back on before quitting")
        enableBuiltInDisplay(builtIn)
    }

    private func enableBuiltInDisplay(_ id: CGDirectDisplayID) {
        if let error = Self.apply(enabled: true, to: id) {
            Self.log.error("Couldn't turn on built-in display: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Enables or disables a display. Returns `nil` on success.
    private static func apply(enabled: Bool, to id: CGDirectDisplayID) -> DisplayError? {
        var config: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&config)
        guard result == .success else { return .coreGraphics(result) }

        result = CGSConfigureDisplayEnabled(config, id, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return .coreGraphics(result)
        }

        // `.forSession` outlives this app and its window, but a log out or restart restores all displays.
        // Use `.permanently` to survive restarts too.
        result = CGCompleteDisplayConfiguration(config, .forSession)
        return result == .success ? nil : .coreGraphics(result)
    }
}

// MARK: - View

struct ContentView: View {
    @Environment(DisplayManager.self) private var manager

    var body: some View {
        Group {
            if manager.displays.isEmpty {
                ContentUnavailableView(
                    "No Displays Found",
                    systemImage: "display",
                    description: Text("Connect a monitor and it will appear here.")
                )
                .frame(height: 220)
            } else {
                Form {
                    Section {
                        ForEach(manager.displays) { display in
                            DisplayRow(display: display)
                        }
                    } header: {
                        Text("Displays")
                    } footer: {
                        footer
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                // Size the window to its rows instead of leaving empty space below them.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 400)
        .animation(.default, value: manager.errorMessage)
    }

    @ViewBuilder
    private var footer: some View {
        if let message = manager.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Text("The built-in display turns back on if no other display is active, or when you quit GoDark.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct DisplayRow: View {
    @Environment(DisplayManager.self) private var manager
    let display: ManagedDisplay

    var body: some View {
        Toggle(isOn: Binding(
            get: { display.isEnabled },
            set: { manager.setEnabled($0, for: display) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(display.isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 32)
            }
        }
        .toggleStyle(.switch)
    }

    private var iconName: String {
        display.isBuiltIn ? "laptopcomputer" : "display"
    }

    private var subtitle: String {
        let kind = display.isBuiltIn ? "Built-in" : "External"
        return "\(kind) · \(display.isEnabled ? "On" : "Off")"
    }
}

#Preview {
    ContentView()
        .environment(DisplayManager())
}
