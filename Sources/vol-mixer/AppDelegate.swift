import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class VolMixerAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MixerStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only utility: no dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                   accessibilityDescription: "Volume Mixer")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        let host = NSHostingController(rootView: ContentView(showsTitle: true).environment(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        store.beginRefreshing()
        autoEnableLaunchAtLoginOnce()
        Updater.shared.startAutomaticChecks()
    }

    @objc private func checkForUpdates() { Updater.shared.checkNow() }
    @objc private func toggleAutoUpdate() { Updater.shared.autoCheckEnabled.toggle() }

    /// On the first launch we auto-register as a Login Item so the menu bar
    /// mixer is always available. Guarded by a UserDefaults flag so that
    /// subsequent user opt-outs are respected — we never re-enable it.
    private func autoEnableLaunchAtLoginOnce() {
        let key = "vol-mixer.didSetInitialLoginItem"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
            NSLog("vol-mixer: auto-registered as Login Item on first launch")
        } catch {
            NSLog("vol-mixer: auto-register failed: %@", "\(error)")
        }
    }

    // MARK: - Status item click

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        switch event.type {
        case .rightMouseUp:
            if popover.isShown { popover.performClose(nil) }
            showContextMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Accessory apps don't auto-activate; without this the popover's hover
        // and keyboard states can feel off.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        // Clicks on other menu-bar items land in a different process, so only a
        // global monitor sees them — use it to close the popover.
        removePopoverClickMonitor()
        popoverClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverClickMonitor()
    }

    private func removePopoverClickMonitor() {
        if let monitor = popoverClickMonitor {
            NSEvent.removeMonitor(monitor)
            popoverClickMonitor = nil
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let launchItem = menuItem(title: "Launch at Login",
                                  action: #selector(toggleLaunchAtLogin),
                                  keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Check for Updates…",
                              action: #selector(checkForUpdates),
                              keyEquivalent: ""))
        let autoUpdate = menuItem(title: "Automatically Update",
                                  action: #selector(toggleAutoUpdate),
                                  keyEquivalent: "")
        autoUpdate.state = Updater.shared.autoCheckEnabled ? .on : .off
        menu.addItem(autoUpdate)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Volume Mixer",
                              action: #selector(quit),
                              keyEquivalent: "q"))

        guard let button = statusItem.button else { return }
        // Show directly — avoids the "attach/performClick/detach" race that can
        // leave the menu without its actions on accessory-policy apps. Drop it
        // just below the button; placing it above ran off the top of the screen,
        // which made macOS clamp it behind a scroll arrow.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
    }

    // An accessory-policy app has no key window, so the responder chain doesn't
    // reliably reach the delegate. Bind target explicitly.
    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                NSLog("vol-mixer: unregistered from Login Items")
            } else {
                try service.register()
                NSLog("vol-mixer: registered as Login Item (status: %@)",
                      "\(service.status.rawValue)")
            }
        } catch {
            NSLog("vol-mixer: SMAppService toggle failed: %@", "\(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Login Item setting"
            alert.informativeText = "\(error.localizedDescription)\n\n" +
                "You can also toggle this in System Settings › General › Login Items."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAll()
    }
}
