import Foundation
import IOKit.ps

/// The Mac's battery, if it has one.
public struct IOPowerSourcesInfo {
    public let level: Double
    public let charging: Bool

    public static func now() -> IOPowerSourcesInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let now = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return IOPowerSourcesInfo(level: Double(now) / Double(max), charging: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
