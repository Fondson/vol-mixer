import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class VolMixerAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let store = MixerStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var fullyQuitting = false
    private var popoverClickMonitor: Any?

    // Remembered across launches: false once the user closes the window, so a
    // login-launched or relaunched app stays a menu-bar-only utility.
    private let showWindowKey = "vol-mixer.showWindowAtLaunch"
    private var showWindowAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showWindowKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showWindowKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

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
        // Auto-size the popover from SwiftUI's intrinsic content size. Bounds
        // (width + maxHeight) are declared on ContentView's root .frame.
        let host = NSHostingController(rootView: ContentView(showsTitle: true).environment(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        store.beginRefreshing()
        // Open the window only if it was open last time (always on first run);
        // at login or after the user closed it, stay menu-bar-only.
        if showWindowAtLaunch {
            showMainWindow()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        autoEnableLaunchAtLoginOnce()
        Updater.shared.startAutomaticChecks()
    }

    @objc private func openMainWindow() { showMainWindow() }
    @objc private func checkForUpdates() { Updater.shared.checkNow() }
    @objc private func toggleAutoUpdate() { Updater.shared.autoCheckEnabled.toggle() }

    private func showMainWindow() {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        showWindowAtLaunch = true
        store.refresh()
        // Bring back the Dock icon (we drop to menu-bar-only when the window closes).
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() -> NSWindow {
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active

        // Hosted inside the blur view at a fixed window size. ignoresSafeArea
        // lets the top row sit beside the floating traffic-light buttons.
        let hosting = NSHostingView(
            rootView: ContentView().environment(store).ignoresSafeArea())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])

        // Size to the content once at creation (clamped) so a short list isn't
        // marooned in a tall window; the inner scroll view handles overflow.
        let fitH = hosting.fittingSize.height
        let height = fitH > 100 ? min(fitH, 600) : 440

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentView = blur
        window.title = "Volume Mixer"
        // No title bar — the traffic-light buttons float over the content.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("VolMixerMainWindow")
        return window
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appName = "Volume Mixer"

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

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
        let type = NSApp.currentEvent?.type
        NSLog("vol-mixer: status item clicked, event type = %@",
              type.map { "\($0.rawValue)" } ?? "nil")
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
        // Re-scan the process list before opening so rows are up-to-date
        // and the popover sizes to current content.
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover key so its controls respond, but don't activate the
        // app — opening the popover shouldn't pull the standalone window forward.
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
        NSLog("vol-mixer: showing context menu")
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Volume Mixer",
                              action: #selector(openMainWindow),
                              keyEquivalent: ""))
        menu.addItem(.separator())
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
        // Show directly — avoids the "attach/performClick/detach" race that
        // can leave the menu without its actions on accessory-policy apps.
        // Drop it just below the button; placing it above ran off the top of
        // the screen, which made macOS clamp it behind a scroll arrow.
        let origin = NSPoint(x: 0, y: -4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    // An accessory-policy app has no key window, so the responder chain
    // doesn't reliably reach the delegate. Bind target explicitly.
    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func quit() {
        NSLog("vol-mixer: menu → quit")
        fullyQuitting = true
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

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // With the window open, Cmd-Q / Dock-Quit just hide it to the menu bar — but
    // never cancel a system logout/shutdown, and quit for real if no window is open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if fullyQuitting || systemIsShuttingDown() { return .terminateNow }
        if let w = mainWindow, w.isVisible {
            w.close()
            return .terminateCancel
        }
        return .terminateNow
    }

    // Logout/shutdown send a quit with a reason code; plain Cmd-Q doesn't.
    // Codes: 'why?' key, then 'logo' 'rlgo' 'rest' 'shut' 'rrst' 'rsdn'.
    private static let quitReasonKey = AEKeyword(0x7768793F)
    private static let systemQuitReasons: Set<OSType> =
        [0x6C6F676F, 0x726C676F, 0x72657374, 0x73687574, 0x72727374, 0x7273646E]
    private func systemIsShuttingDown() -> Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: Self.quitReasonKey)?.enumCodeValue
        else { return false }
        return Self.systemQuitReasons.contains(reason)
    }

    // Closing the window drops the Dock icon and is remembered, so the app
    // launches menu-bar-only next time (including at login).
    func windowWillClose(_ notification: Notification) {
        guard !fullyQuitting else { return }
        showWindowAtLaunch = false
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAll()
    }
}
