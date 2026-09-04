import AppKit
import ApplicationServices

/// Watches every regular app in the session and remembers, per process, the order in which
/// its windows were last in the foreground. Most recent first.
final class WindowTracker {
    static let shared = WindowTracker()

    private var recencyByPID: [pid_t: [CGWindowID]] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false

    private static let watchedNotifications = [
        kAXApplicationActivatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
    ]

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications {
            attach(to: app)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            recordFocusedWindow(of: front.processIdentifier)
        }
    }

    // MARK: - Recency bookkeeping

    func record(pid: pid_t, windowID: CGWindowID) {
        var order = recencyByPID[pid] ?? []
        order.removeAll { $0 == windowID }
        order.insert(windowID, at: 0)
        recencyByPID[pid] = order
    }

    /// `candidates` in most-recently-foregrounded order. Windows we have never seen focused
    /// fall back to the window server's front-to-back order, which is a decent approximation.
    func sortByRecency(_ candidates: [Window], pid: pid_t) -> [Window] {
        let recency = recencyByPID[pid] ?? []
        let recencyRank = Dictionary(
            uniqueKeysWithValues: recency.enumerated().map { ($0.element, $0.offset) })
        let zOrderRank = Self.frontToBackRank(pid: pid)

        return candidates.enumerated().sorted { lhs, rhs in
            let l = recencyRank[lhs.element.id]
            let r = recencyRank[rhs.element.id]
            switch (l, r) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let lz = zOrderRank[lhs.element.id] ?? Int.max
                let rz = zOrderRank[rhs.element.id] ?? Int.max
                return lz == rz ? lhs.offset < rhs.offset : lz < rz
            }
        }.map(\.element)
    }

    private static func frontToBackRank(pid: pid_t) -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var rank: [CGWindowID: Int] = [:]
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            rank[id] = rank.count
        }
        return rank
    }

    private func recordFocusedWindow(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute),
            let id = window.windowID
        else { return }
        record(pid: pid, windowID: id)
    }

    // MARK: - Observation

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy != .prohibited, pid > 0, observers[pid] == nil,
            pid != ProcessInfo.processInfo.processIdentifier
        else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.watchedNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func handle(notification: String, element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }

        if notification == kAXApplicationActivatedNotification {
            recordFocusedWindow(of: pid)
        } else if let id = element.windowID {
            record(pid: pid, windowID: id)
        }
    }

    // MARK: - Workspace notifications

    @objc private func applicationLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        // Apps rarely have their AX tree ready the instant they launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.attach(to: app)
        }
    }

    @objc private func applicationTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        recencyByPID.removeValue(forKey: pid)
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        attach(to: app)
        recordFocusedWindow(of: app.processIdentifier)
    }
}
