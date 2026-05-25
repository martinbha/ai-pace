import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct AIPaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        let _ = appDelegate.configureIfNeeded(store: store)

        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var optionsWindowController: OptionsWindowController?
    private var hotKeyManager: GlobalHotKeyManager?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerKeyboardShortcuts()
    }

    func configureIfNeeded(store: UsageStore) {
        guard statusItemController == nil else {
            return
        }
        let openSettings: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.showOptionsWindow(with: store)
        }
        statusItemController = StatusItemController(store: store, openSettings: openSettings)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showOptionsWindow(with store: UsageStore) {
        if optionsWindowController == nil {
            optionsWindowController = OptionsWindowController(store: store)
        }
        optionsWindowController?.show()
    }

    private func registerKeyboardShortcuts() {
        hotKeyManager = GlobalHotKeyManager { [weak self] in
            self?.statusItemController?.toggleFloatingMode()
        }
        updateRegisteredShortcut()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRegisteredShortcut()
            }
        }
    }

    private func updateRegisteredShortcut() {
        let savedKeyCode = UserDefaults.standard.integer(forKey: "floatingWindowShortcutKeyCode")
        let keyCode: UInt16 = savedKeyCode != 0 ? UInt16(savedKeyCode) : 19
        let savedModifiers = UserDefaults.standard.integer(forKey: "floatingWindowShortcutModifiers")
        let modifiers = NSEvent.ModifierFlags(rawValue: savedModifiers != 0 ? UInt(savedModifiers) : (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue))

        hotKeyManager?.register(keyCode: keyCode, modifiers: modifiers)
    }

    @MainActor
    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
}

private final class GlobalHotKeyManager: @unchecked Sendable {
    private static let signature = fourCharCode("AIPC")
    private static let hotKeyID = UInt32(1)

    private let action: @MainActor () -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var registeredShortcut: KeyboardShortcut?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        guard registeredShortcut != shortcut else {
            return
        }

        unregister()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers.carbonHotKeyFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )

        guard status == noErr, let newHotKeyRef else {
            registeredShortcut = nil
            return
        }

        hotKeyRef = newHotKeyRef
        registeredShortcut = shortcut
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
    }

    @MainActor
    private func fire() {
        action()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKeyManager.signature,
                      hotKeyID.id == GlobalHotKeyManager.hotKeyID else {
                    return noErr
                }

                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.fire()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}

private struct KeyboardShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

private extension NSEvent.ModifierFlags {
    var carbonHotKeyFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
