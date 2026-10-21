//
//  ContentView.swift
//  GoDark
//
//  Created by Dina Basumatary on 21/10/2026.
//

import SwiftUI
import AppKit
import CoreGraphics

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
        let callbackResult = CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            let address = Int(bitPattern: userInfo)
            Task { @MainActor in
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<DisplayManager>.fromOpaque(pointer).takeUnretainedValue().displaysDidReconfigure()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        if callbackResult != .success {
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
    }

    // MARK: Detection

    /// Called for every completed CoreGraphics display change, including unplugging a monitor.
    private func displaysDidReconfigure() {
        refresh()
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            // Right after an unplug the active list can still include the removed monitor,
            // so check again once the system has settled.
            for delay in [Duration.seconds(1), .seconds(3)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private var recheckTask: Task<Void, Never>?

    func refresh() {
        // Safety net: if every display ends up off (e.g. the last external monitor was unplugged
        // while the built-in display was disabled), turn the built-in display back on.
        if Self.displayIDs(.active).isEmpty {
            restoreBuiltInDisplay()
        }

        // macOS omits disabled displays from the public active and online lists.
        // `CGSGetDisplayList` still reports them, so use it to find displays that can be switched back on.
        let active = Set(Self.displayIDs(.active))

        displays = Self.displayIDs(.all)
            .map { id in
                let isBuiltIn = CGDisplayIsBuiltin(id) != 0
                if let name = Self.screenName(for: id), knownNames[id] != name { knownNames[id] = name }
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
        let active = Set(Self.displayIDs(.active))
        guard let builtIn = Self.displayIDs(.all).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              !active.contains(builtIn) else { return }
        if let error = Self.apply(enabled: true, to: builtIn) {
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
