import AppKit
import ApplicationServices

struct Window {
    let id: CGWindowID
    let element: AXUIElement
    let isMinimized: Bool
}

/// Raises an app's windows one at a time. Consecutive clicks on the same Dock icon continue
/// walking a single snapshot of the window order, so a repeated click keeps advancing instead
/// of ping-ponging between the two most recent windows.
final class WindowCycler {
    static let shared = WindowCycler()

    private struct Session {
        let pid: pid_t
        var order: [CGWindowID]
        var index: Int
        var raised: CGWindowID
    }

    private var session: Session?

    func cycle(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)

        // A hidden app has nothing to cycle through until its windows are back.
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            app.unhide()
            session = nil
        }

        let windows = cyclableWindows(of: appElement)
        guard !windows.isEmpty else {
            NSRunningApplication(processIdentifier: pid)?.activateApp()
            return
        }
        guard windows.count > 1 else {
            session = nil
            raise(windows[0], pid: pid, appElement: appElement)
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let focusedID = appElement.element(kAXFocusedWindowAttribute)?.windowID
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

        var order: [CGWindowID]
        var index: Int

        if var live = continuingSession(pid: pid, focusedID: focusedID, isFrontmost: isFrontmost) {
            // Drop windows that closed since the snapshot without losing our place.
            let position = live.order.prefix(live.index + 1).filter { byID[$0] != nil }.count - 1
            live.order = live.order.filter { byID[$0] != nil }
            live.order.append(contentsOf: windows.map(\.id).filter { !live.order.contains($0) })
            order = live.order
            index = (max(position, 0) + 1) % order.count
        } else {
            order = WindowTracker.shared.sortByRecency(windows, pid: pid).map(\.id)
            if isFrontmost, let focusedID, let current = order.firstIndex(of: focusedID) {
                index = (current + 1) % order.count
            } else {
                // Coming from another app: the first click behaves like a normal Dock click.
                index = 0
            }
        }

        guard let target = byID[order[index]] else { return }
        session = Session(pid: pid, order: order, index: index, raised: target.id)
        raise(target, pid: pid, appElement: appElement)
    }

    func invalidateSession() {
        session = nil
    }

    private func continuingSession(pid: pid_t, focusedID: CGWindowID?, isFrontmost: Bool) -> Session? {
        guard let session, session.pid == pid, isFrontmost, session.raised == focusedID else {
            return nil
        }
        return session
    }

    // MARK: - Window enumeration

    private func cyclableWindows(of appElement: AXUIElement) -> [Window] {
        appElement.elements(kAXWindowsAttribute).compactMap { element -> Window? in
            let subrole = element.subrole
            // Sheets, popovers and palettes are not things you cycle between.
            guard subrole == nil || subrole == kAXStandardWindowSubrole else { return nil }
            guard let id = element.windowID else { return nil }
            let minimized = element.bool(kAXMinimizedAttribute) ?? false
            guard !minimized || Preferences.shared.includeMinimized else { return nil }
            return Window(id: id, element: element, isMinimized: minimized)
        }
    }

    // MARK: - Raising

    private func raise(_ window: Window, pid: pid_t, appElement: AXUIElement) {
        guard window.isMinimized else {
            focus(window, pid: pid, appElement: appElement)
            return
        }
        window.element.set(kAXMinimizedAttribute, kCFBooleanFalse)
        // Deminiaturisation is animated; the raise only sticks once it has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            focus(window, pid: pid, appElement: appElement)
        }
    }

    private func focus(_ window: Window, pid: pid_t, appElement: AXUIElement) {
        if WindowActivation.raiseOnly(windowID: window.id, pid: pid) {
            // Orders the window to the top within its own app without disturbing the app's
            // position relative to other apps, which SkyLight has already handled.
            window.element.perform(kAXRaiseAction)
        } else {
            // Fallback: whole-app activation. Every window of the app comes forward together,
            // because that is all the public API can express.
            window.element.perform(kAXRaiseAction)
            window.element.set(kAXMainAttribute, kCFBooleanTrue)
            window.element.set(kAXFocusedAttribute, kCFBooleanTrue)
            appElement.set(kAXFrontmostAttribute, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: pid)?.activateApp()
        }
        WindowTracker.shared.record(pid: pid, windowID: window.id)
    }
}

extension NSRunningApplication {
    func activateApp() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(options: [.activateIgnoringOtherApps])
        }
    }
}
