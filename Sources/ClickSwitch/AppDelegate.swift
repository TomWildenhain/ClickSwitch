import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var servicesStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        if AXIsProcessTrusted() {
            startServices()
        } else {
            requestAccessibility()
            waitForAccessibility()
        }
    }

    // MARK: - Services

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        WindowTracker.shared.start()
        _ = DockClickInterceptor.shared.start()
        updateStatusItemImage()
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func waitForAccessibility() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startServices()
        }
    }

    private var isHealthy: Bool {
        AXIsProcessTrusted() && DockClickInterceptor.shared.isRunning
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItemImage()
    }

    private func updateStatusItemImage() {
        let symbol = isHealthy ? "square.stack.3d.up" : "square.stack.3d.up.slash"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "ClickSwitch")
        statusItem.button?.toolTip = isHealthy
            ? "ClickSwitch: \(Preferences.shared.cycleModifierSummary) a Dock icon to cycle windows"
            : "ClickSwitch needs Accessibility permission"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateStatusItemImage()

        if isHealthy {
            let modifiers = Preferences.shared.cycleModifierSummary
            menu.addItem(disabled("\(modifiers) a Dock icon to cycle its windows"))
        } else {
            menu.addItem(disabled("Needs Accessibility permission"))
            menu.addItem(
                item("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())

        let modifierItem = NSMenuItem()
        modifierItem.title = "Cycle Modifier"
        let modifierMenu = NSMenu()

        let multiple = item("Multiple", #selector(toggleMultipleModifiers))
        multiple.state = Preferences.shared.allowsMultipleModifiers ? .on : .off
        multiple.toolTip = "Allow more than one modifier to trigger cycling"
        modifierMenu.addItem(multiple)
        modifierMenu.addItem(.separator())

        let selected = Preferences.shared.cycleModifiers
        for modifier in CycleModifier.allCases {
            let entry = item(modifier.title, #selector(selectModifier(_:)))
            entry.representedObject = modifier
            entry.state = selected.contains(modifier) ? .on : .off
            modifierMenu.addItem(entry)
        }
        modifierItem.submenu = modifierMenu
        menu.addItem(modifierItem)

        let minimized = item("Include Minimized Windows", #selector(toggleIncludeMinimized))
        minimized.state = Preferences.shared.includeMinimized ? .on : .off
        menu.addItem(minimized)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit ClickSwitch", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func selectModifier(_ sender: NSMenuItem) {
        guard let modifier = sender.representedObject as? CycleModifier else { return }
        let preferences = Preferences.shared

        guard preferences.allowsMultipleModifiers else {
            preferences.cycleModifiers = [modifier]
            updateStatusItemImage()
            return
        }

        var selection = preferences.cycleModifiers
        if selection.contains(modifier) {
            // Refuse to clear the last one; an empty selection would make the app do nothing.
            guard selection.count > 1 else { return }
            selection.remove(modifier)
        } else {
            selection.insert(modifier)
        }
        preferences.cycleModifiers = selection
        updateStatusItemImage()
    }

    @objc private func toggleMultipleModifiers() {
        let preferences = Preferences.shared
        preferences.allowsMultipleModifiers.toggle()
        if !preferences.allowsMultipleModifiers {
            preferences.keepOnlyFirstCycleModifier()
        }
        updateStatusItemImage()
    }

    @objc private func toggleIncludeMinimized() {
        Preferences.shared.includeMinimized.toggle()
        WindowCycler.shared.invalidateSession()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change the Launch at Login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        requestAccessibility()
        let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        DockClickInterceptor.shared.stop()
        NSApp.terminate(nil)
    }
}
