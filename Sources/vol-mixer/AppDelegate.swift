import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class VolMixerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = MixerStore()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var mainWindow: NSWindow?
    private var fullyQuitting = false
    private var clickMonitor: Any?
    private var panelResignObserver: Any?
    // When the panel closes because it lost focus, this records when — so the
    // same click that asked to toggle it doesn't immediately reopen it.
    private var lastPanelResignClose: Date?
    // What an open surface was last sized for (see fitKey), so a live refresh
    // re-measures only when something that changes the height changed.
    private var lastFitKey = ""

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

        store.onProcessesChanged = { [weak self] in self?.refitOpenSurfaces() }
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
        fitWindowHeight()   // built once, so re-fit to the current list on each open
        // Bring back the Dock icon (we drop to menu-bar-only when the window closes).
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() -> NSWindow {
        // ignoresSafeArea lets the top row sit beside the floating traffic-light
        // buttons; the window rounds its own corners, so it passes no mask here.
        let hosting = NSHostingView(
            rootView: ContentView().environment(store).ignoresSafeArea())
        let blur = Self.frostedContainer(hosting: hosting, cornerRadius: nil)

        // A default height; showMainWindow resizes it to the current list on open.
        let height: CGFloat = 440

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
        guard let event = NSApp.currentEvent else { togglePanel(); return }
        switch event.type {
        case .rightMouseUp:
            closePanel()
            showContextMenu()
        default:
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else if let t = lastPanelResignClose, Date().timeIntervalSince(t) < 0.25 {
            // The panel already closed itself a moment ago when this same click
            // pulled focus away — don't bounce it straight back open.
            lastPanelResignClose = nil
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // Rebuilt on each open: opens are user-initiated so the cost is trivial,
        // and tearing it down on close stops it re-rendering while hidden.
        closePanel()
        store.refresh()
        let p = makePanel()
        panel = p

        fitPanelHeight()
        p.makeKeyAndOrderFront(nil)

        // Close when the panel loses focus — this covers Cmd-Tab, Mission Control,
        // and clicks in our own window, which the global monitor below can't see.
        panelResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lastPanelResignClose = Date()
                self?.closePanel()
            }
        }
        // Clicks in other apps or other menu-bar items don't always pull focus
        // away from the panel, so a global mouse monitor backstops those.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        removeClickMonitor()
        if let obs = panelResignObserver {
            NotificationCenter.default.removeObserver(obs)
            panelResignObserver = nil
        }
    }

    private func positionPanel(_ p: NSPanel) {
        guard let button = statusItem.button, let bWin = button.window else { return }
        let b = bWin.convertToScreen(button.convert(button.bounds, to: nil))
        var size = p.frame.size
        var x = b.midX - size.width / 2
        let top = b.minY - 6
        var y = top - size.height
        if let vis = (bWin.screen ?? NSScreen.main)?.visibleFrame {
            x = max(vis.minX + 8, min(x, vis.maxX - size.width - 8))
            // Too tall for the space below the menu bar: shrink it so the bottom
            // stays on screen (the list scrolls inside the shorter panel).
            let lowest = vis.minY + 8
            if y < lowest {
                size.height = top - lowest
                p.setContentSize(size)
                y = lowest
            }
        }
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makePanel() -> MixerPanel {
        let hosting = NSHostingView(rootView: ContentView(showsTitle: true).environment(store))
        let blur = Self.frostedContainer(hosting: hosting, cornerRadius: 12)

        let p = MixerPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.contentView = blur
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    // The shown list scrolls, so its hosting view reports a collapsed height.
    // Measure a copy rendered unscrolled instead; cap so a long list scrolls.
    private func contentHeight(showsTitle: Bool) -> CGFloat {
        let probe = NSHostingView(
            rootView: ContentView(showsTitle: showsTitle, measuring: true).environment(store))
        return min(probe.fittingSize.height, 600)
    }

    // Re-fit an open surface so its height tracks the list. The 2s refresh fires
    // every tick, so skip unless the height-affecting state changed (see fitKey).
    private func refitOpenSurfaces() {
        guard panel != nil || (mainWindow?.isVisible ?? false) else { return }
        guard fitKey() != lastFitKey else { return }
        if panel != nil { fitPanelHeight() }
        if mainWindow?.isVisible ?? false { fitWindowHeight() }
    }

    // What changes the list's height: row count plus how many rows show an error
    // line. Watching `errors` directly would fire on every slider drag, so avoid it.
    private func fitKey() -> String {
        let errorRows = store.processes.reduce(into: 0) { n, p in
            if store.errors[p.pid] != nil { n += 1 }
        }
        return "\(store.processes.count)/\(errorRows)"
    }

    private func fitPanelHeight() {
        guard let p = panel else { return }
        lastFitKey = fitKey()
        p.setContentSize(NSSize(width: 560, height: contentHeight(showsTitle: true)))
        positionPanel(p)
        p.invalidateShadow()
    }

    private func fitWindowHeight() {
        guard let w = mainWindow else { return }
        lastFitKey = fitKey()
        let top = w.frame.maxY   // keep the top edge fixed; grow/shrink downward
        var h = contentHeight(showsTitle: false)
        var bottom = top - h
        // Keep the bottom on screen like the panel does; the list scrolls inside
        // the shorter window rather than running off a short display.
        if let vis = (w.screen ?? NSScreen.main)?.visibleFrame, bottom < vis.minY + 8 {
            bottom = vis.minY + 8
            h = top - bottom
        }
        w.setFrame(NSRect(x: w.frame.minX, y: bottom, width: 560, height: h),
                   display: true, animate: false)
    }

    private static func frostedContainer(hosting: NSView, cornerRadius: CGFloat?) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            glass.cornerRadius = cornerRadius ?? 0
            if let r = cornerRadius {
                // cornerRadius rounds the glass material, but the window shadow
                // follows the square layer corners — clip the layer to match.
                glass.wantsLayer = true
                glass.layer?.cornerRadius = r
                glass.layer?.masksToBounds = true
            }
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        if let r = cornerRadius {
            // The blur ignores layer corner rounding, so round it with a mask image.
            blur.maskImage = roundedMask(radius: r)
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])
        return blur
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // A stretchable rounded square: the corner insets stay fixed while the
    // middle scales, so the panel's corners round at any size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: d, height: d),
                     xRadius: radius, yRadius: radius).fill()
        image.unlockFocus()
        image.resizingMode = .stretch
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        return image
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

// A borderless panel won't become key by default, so its sliders would need a
// throwaway first click. Overriding this lets them respond immediately.
private final class MixerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
