import AppKit
import ObjectiveC

/// Assistive clients announce themselves to the application, before walking
/// its windows. Chromium lives in YabCore, so AppKit cannot enable its trees
/// for us. Keep the two client switches on the owning app and engage the same
/// page bridge used by a tree walk; never make a client retry a focus query
/// merely to announce that it needs accessibility.
@MainActor
enum ChromiumAccessibilityClient {
    private static var installed = false
    private static var enabled: Set<String> = []
    private static let attributes = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    static func install() {
        guard !installed else { return }
        installed = true
        let applicationClass: AnyClass = type(of: NSApplication.shared)

        let names = NSSelectorFromString("accessibilityAttributeNames")
        if let method = class_getInstanceMethod(applicationClass, names) {
            typealias Original = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (AnyObject) -> NSArray = { object in
                let previous = original(object, names)?.takeUnretainedValue() as? [String] ?? []
                return (previous + attributes.filter { !previous.contains($0) }) as NSArray
            }
            class_replaceMethod(applicationClass, names, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }

        let read = NSSelectorFromString("accessibilityAttributeValue:")
        if let method = class_getInstanceMethod(applicationClass, read) {
            typealias Original = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<NSObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (AnyObject, NSString) -> NSObject? = { object, attribute in
                if attributes.contains(attribute as String) { return NSNumber(value: enabled.contains(attribute as String)) }
                return original(object, read, attribute)?.takeUnretainedValue()
            }
            class_replaceMethod(applicationClass, read, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }

        let settable = NSSelectorFromString("accessibilityIsAttributeSettable:")
        if let method = class_getInstanceMethod(applicationClass, settable) {
            typealias Original = @convention(c) (AnyObject, Selector, NSString) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (AnyObject, NSString) -> Bool = { object, attribute in
                attributes.contains(attribute as String) || original(object, settable, attribute)
            }
            class_replaceMethod(applicationClass, settable, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }

        let write = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if let method = class_getInstanceMethod(applicationClass, write) {
            typealias Original = @convention(c) (AnyObject, Selector, NSObject?, NSString) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let hook: @convention(block) (AnyObject, NSObject?, NSString) -> Void = { object, value, attribute in
                guard attributes.contains(attribute as String), let flag = value as? NSNumber else {
                    original(object, write, value, attribute)
                    return
                }
                if flag.boolValue {
                    enabled.insert(attribute as String)
                    ChromiumRemoteAccessibility.engage()
                } else {
                    enabled.remove(attribute as String)
                }
            }
            class_replaceMethod(applicationClass, write, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
        }
    }
}
