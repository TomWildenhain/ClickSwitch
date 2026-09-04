import ApplicationServices
import Foundation

/// `_AXUIElementGetWindow` is the only way to map an `AXUIElement` to the `CGWindowID`
/// that the rest of the system uses to identify a window. It is SPI, so it is resolved at
/// runtime and everything degrades to element identity if it ever disappears.
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private let axGetWindow: AXGetWindowFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(symbol, to: AXGetWindowFn.self)
}()

extension AXUIElement {
    var windowID: CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        guard axGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }

    func rawValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        rawValue(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        rawValue(attribute) as? Bool
    }

    func url(_ attribute: String) -> URL? {
        rawValue(attribute) as? URL
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = rawValue(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let value = rawValue(attribute), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var parent: AXUIElement? { element(kAXParentAttribute) }
}
