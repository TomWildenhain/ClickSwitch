import AppKit
import ApplicationServices

/// Answers "which running application's Dock icon is under this point?".
///
/// The Dock exposes its tiles through the Accessibility API, so a hit test against the Dock
/// process tells us exactly what the user aimed at — including tiles that have moved because
/// of magnification, a hidden Dock, or a Dock on a secondary display.
enum DockHitTester {
    private static let applicationDockItem = "AXApplicationDockItem"
    private static let urlAttribute = "AXURL"
    private static let isRunningAttribute = "AXIsApplicationRunning"

    private static var cachedDock: (pid: pid_t, element: AXUIElement)?

    /// Comfortably clears a Dock at the 128pt maximum tile size, magnification included.
    private static let dockEdgeMargin: CGFloat = 200

    static func runningApplication(at point: CGPoint) -> NSRunningApplication? {
        // Once plain clicks are a trigger this runs for every left click on the machine, so
        // reject the overwhelming majority with screen arithmetic before touching the AX API.
        guard isNearScreenEdge(point) else { return nil }
        guard let dock = dockElement() else { return nil }

        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success,
            let tile = applicationTile(from: hit)
        else { return nil }

        guard tile.bool(isRunningAttribute) == true else { return nil }
        return resolveApplication(for: tile)
    }

    /// The hit may land on a label or badge inside the tile, so walk up to the tile itself.
    private static func applicationTile(from element: AXUIElement?) -> AXUIElement? {
        var current = element
        for _ in 0..<4 {
            guard let candidate = current else { return nil }
            if candidate.subrole == applicationDockItem { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private static func resolveApplication(for tile: AXUIElement) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications

        if let url = tile.url(urlAttribute)?.canonicalPath {
            if let match = apps.first(where: { $0.bundleURL?.canonicalPath == url }) {
                return match
            }
            if let bundleID = Bundle(url: URL(fileURLWithPath: url))?.bundleIdentifier,
                let match = apps.first(where: { $0.bundleIdentifier == bundleID })
            {
                return match
            }
        }

        guard let title = tile.string(kAXTitleAttribute) else { return nil }
        return apps.first { $0.localizedName == title && $0.activationPolicy == .regular }
    }

    /// The Dock is always flush against the bottom, left or right edge of some display, so a
    /// point far from every edge cannot be on it. Necessary condition only — the AX hit test
    /// still decides.
    private static func isNearScreenEdge(_ point: CGPoint) -> Bool {
        // CGEvent locations are top-left origin; NSScreen frames are bottom-left origin
        // relative to the primary display.
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return true }

        for screen in NSScreen.screens {
            let frame = screen.frame
            let bounds = CGRect(
                x: frame.minX, y: primaryHeight - frame.maxY,
                width: frame.width, height: frame.height)
            guard bounds.contains(point) else { continue }
            return point.y >= bounds.maxY - dockEdgeMargin
                || point.x <= bounds.minX + dockEdgeMargin
                || point.x >= bounds.maxX - dockEdgeMargin
        }
        return false
    }

    private static func dockElement() -> AXUIElement? {
        let dockPID = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.dock" }?
            .processIdentifier

        guard let dockPID else {
            cachedDock = nil
            return nil
        }
        if let cachedDock, cachedDock.pid == dockPID { return cachedDock.element }

        let element = AXUIElementCreateApplication(dockPID)
        // This runs inside the event tap callback, which the system will disable if it stalls.
        AXUIElementSetMessagingTimeout(element, 0.25)
        cachedDock = (dockPID, element)
        return element
    }
}

extension URL {
    fileprivate var canonicalPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }
}
