import AppKit
import CoreGraphics

/// Watches for modifier+click on the Dock and, when it lands on a running application's tile,
/// swallows the click and cycles that application's windows instead.
final class DockClickInterceptor {
    static let shared = DockClickInterceptor()

    /// What the in-flight left click has already committed us to.
    private enum ClickState {
        case idle
        /// A modifier click already cycled on mouse down; its mouse up must not reach the Dock.
        case cycled
        /// A plain click on a Dock tile. Plain clicks are also how the Dock is rearranged, so
        /// nothing is decided until we see whether this turns into a drag.
        case undecided(pid: pid_t, origin: CGPoint)
    }

    /// Far enough to be a deliberate drag, close enough that the cursor is still on the tile.
    private static let dragThreshold: CGFloat = 5

    /// Marks the mouse down we re-post when handing a drag back, so we ignore our own event.
    private static let syntheticEventMarker: Int64 = 0x434C_5357

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickState = ClickState.idle

    func start() -> Bool {
        guard !isRunning else { return true }

        let mask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<DockClickInterceptor>.fromOpaque(refcon)
                .takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables slow taps. Re-arm rather than silently dying.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough

        case .leftMouseDown:
            // Our own hand-off event, on its way to the Dock.
            guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker
            else { return passThrough }

            clickState = .idle
            guard let modifier = Preferences.shared.matchedCycleModifier(event.flags),
                let app = DockHitTester.runningApplication(at: event.location)
            else { return passThrough }

            let pid = app.processIdentifier
            guard modifier != .plain else {
                // Swallow it for now. The Dock never starts tracking, so if this turns out to
                // be a drag we hand the whole gesture back below.
                clickState = .undecided(pid: pid, origin: event.location)
                return nil
            }
            cycle(pid: pid)
            clickState = .cycled
            return nil

        case .leftMouseDragged:
            guard case .undecided(_, let origin) = clickState else { return passThrough }
            let travelled = hypot(event.location.x - origin.x, event.location.y - origin.y)
            guard travelled > Self.dragThreshold else { return passThrough }

            // A drag, not a click: give the gesture back so Dock icons stay rearrangeable.
            clickState = .idle
            postSyntheticMouseDown(at: event.location, flags: event.flags)
            // Swallow this one so the re-posted mouse down reaches the Dock ahead of it.
            return nil

        case .leftMouseUp:
            switch clickState {
            case .idle:
                return passThrough
            case .cycled:
                clickState = .idle
                return nil
            case .undecided(let pid, _):
                clickState = .idle
                cycle(pid: pid)
                return nil
            }

        default:
            return passThrough
        }
    }

    /// Always off the tap: the system disables taps whose callback is slow, and an unresponsive
    /// target app can make the Accessibility calls block.
    private func cycle(pid: pid_t) {
        DispatchQueue.main.async { WindowCycler.shared.cycle(pid: pid) }
    }

    /// Replays the mouse down we swallowed, so the Dock can run its own drag tracking. Posting
    /// at the current location rather than the original avoids warping the cursor; within the
    /// drag threshold the two are the same tile anyway.
    private func postSyntheticMouseDown(at location: CGPoint, flags: CGEventFlags) {
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cgSessionEventTap)
    }
}
