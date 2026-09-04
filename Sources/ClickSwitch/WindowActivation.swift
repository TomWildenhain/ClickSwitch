import AppKit
import ApplicationServices

/// macOS activates *applications*, not windows: anything built on `NSRunningApplication.activate`
/// or `AXFrontmost` brings the app's entire window group above the other apps'. Getting the
/// Windows-style result — only the window you picked comes forward, its siblings stay where they
/// are — means going through SkyLight's per-window activation SPI, which is the same path the
/// window server takes when you click directly on a single background window.
///
/// These symbols are private, so they are resolved at runtime and the caller falls back to
/// ordinary app activation if they ever disappear.
enum WindowActivation {
    private typealias SetFrontProcessFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventRecordFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    /// Raise the app front but only the window passed alongside it.
    private static let kCPSUserGenerated: UInt32 = 0x200

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(handle, to: type)
    }

    private static let setFrontProcess = symbol(
        "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecord = symbol(
        "SLPSPostEventRecordTo", as: PostEventRecordFn.self)
    private static let processSerialNumber = symbol(
        "GetProcessForPID", as: GetProcessForPIDFn.self)

    /// Brings `windowID` to the front on its own and makes it key.
    /// Returns `false` when the SPI is unavailable so the caller can fall back.
    static func raiseOnly(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processSerialNumber else {
            return false
        }

        var psn = ProcessSerialNumber()
        guard processSerialNumber(pid, &psn) == noErr else { return false }
        guard setFrontProcess(&psn, windowID, kCPSUserGenerated) == .success else { return false }

        makeKey(windowID: windowID, psn: &psn, post: postEventRecord)
        return true
    }

    /// Bringing the window forward does not make it key on its own. The window server expects a
    /// two-phase synthetic event record naming the window; without it the window is visible but
    /// keyboard focus stays put.
    private static func makeKey(
        windowID: CGWindowID, psn: inout ProcessSerialNumber, post: PostEventRecordFn
    ) {
        var id = windowID
        for phase: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = phase
            bytes[0x3a] = 0x10
            memset(&bytes[0x20], 0xff, 0x10)
            memcpy(&bytes[0x3c], &id, MemoryLayout<CGWindowID>.size)
            _ = post(&psn, &bytes)
        }
    }
}
