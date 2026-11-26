//
//  DisplayShortcuts.swift
//  GoDark
//

import AppKit
import Carbon.HIToolbox
import os

/// System-wide shortcuts: ⌃⇧1 to ⌃⇧9 toggle the displays in the order the window lists them.
///
/// These use Carbon hot keys, which work while GoDark is in the background, inside the App Sandbox
/// and without Accessibility permission. That matters here: with the built-in display off and the
/// window closed, a shortcut is the quickest way to switch it back on.
final class DisplayShortcuts {
    static let modifierSymbols = "⌃⇧"

    /// Virtual key codes of the number row. They aren't sequential, so they're listed in order.
    private static let keyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    static var count: Int { keyCodes.count }

    /// "GDrk", identifies our hot keys in Carbon events.
    nonisolated private static let signature: OSType = 0x4744_726B

    private let manager: DisplayManager
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init(manager: DisplayManager) {
        self.manager = manager

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The shortcuts live for the whole app, so an unretained reference is safe.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userInfo in
            var hotKeyID = EventHotKeyID()
            guard let event, let userInfo, GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            ) == noErr, hotKeyID.signature == DisplayShortcuts.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let index = Int(hotKeyID.id)
            let address = Int(bitPattern: userInfo)
            Task { @MainActor in
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<DisplayShortcuts>.fromOpaque(pointer).takeUnretainedValue().toggleDisplay(at: index)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            DisplayManager.log.error("Couldn't install hot key handler: \(status, privacy: .public)")
            return
        }

        for (index, keyCode) in Self.keyCodes.enumerated() {
            var hotKey: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(controlKey | shiftKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                // Usually another app already owns this shortcut.
                DisplayManager.log.error("Couldn't register \(Self.modifierSymbols, privacy: .public)\(index + 1, privacy: .public): \(status, privacy: .public)")
            }
        }
    }

    private func toggleDisplay(at index: Int) {
        // Pick up any change that hasn't been reported yet, so the index matches the window.
        manager.refresh()
        guard manager.displays.indices.contains(index) else { return }
        let display = manager.displays[index]
        DisplayManager.log.info("Shortcut \(index + 1, privacy: .public) toggles display \(display.id, privacy: .public)")
        manager.setEnabled(!display.isEnabled, for: display)
    }
}
