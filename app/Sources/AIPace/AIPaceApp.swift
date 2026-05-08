import AppKit
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
    private var keyboardMonitor: Any?

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
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let savedKeyCode = UserDefaults.standard.integer(forKey: "floatingWindowShortcutKeyCode")
        let keyCode: UInt16 = savedKeyCode != 0 ? UInt16(savedKeyCode) : 19
        let savedModifiers = UserDefaults.standard.integer(forKey: "floatingWindowShortcutModifiers")
        let modifiers = NSEvent.ModifierFlags(rawValue: savedModifiers != 0 ? UInt(savedModifiers) : (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue))

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers, event.keyCode == keyCode {
            statusItemController?.toggleFloatingMode()
            return nil
        }

        return event
    }

    @MainActor
    deinit {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
