import ApplicationServices
import Foundation

// Small, forgiving wrappers over the C Accessibility API.
// (From the M1 page-text spike.)

public func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

public func axString(_ el: AXUIElement, _ name: String) -> String? {
    axAttr(el, name) as? String
}

public func axElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = axAttr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

public func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

public func axParam(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &value)
    return err == .success ? value : nil
}

@discardableResult
public func axSetBool(_ el: AXUIElement, _ name: String, _ on: Bool) -> AXError {
    AXUIElementSetAttributeValue(el, name as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
}

/// Reads several attributes in one IPC round trip. Missing attributes come back as nil.
public func axMany(_ el: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(
        el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
    guard err == .success, let arr = values as? [AnyObject], arr.count == names.count else {
        return names.map { axAttr(el, $0) }
    }
    return arr.map { v in
        // A missing attribute is returned as an AXValue wrapping an AXError.
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError {
            return nil
        }
        return v
    }
}

/// Breadth-first search for the first element with the given role (the top-level page, not an iframe).
public func findFirst(role: String, under root: AXUIElement, limit: Int = 4000) -> AXUIElement? {
    var queue = [root]
    var seen = 0
    while !queue.isEmpty && seen < limit {
        let el = queue.removeFirst()
        seen += 1
        if axString(el, kAXRoleAttribute as String) == role { return el }
        queue.append(contentsOf: axChildren(el))
    }
    return nil
}

public func now() -> Double { CFAbsoluteTimeGetCurrent() }
public func ms(since t: Double) -> Int { Int(((now() - t) * 1000).rounded()) }

public func pump(seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
