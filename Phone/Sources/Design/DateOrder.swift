import Foundation

// Xcode 27.2's SDK declares Date's >= and <= @backDeployed(before: iOS 27.2),
// so a build with it calls Foundation's own symbol on 27.2, which the 27.2
// seeds lack: 0.1.33 jumped to address zero at launch (#1708, #1719). These
// shadow Foundation's in every module that compiles this file (the app,
// SyncKit and each extension, Phone/project.yml), so the binaries never
// import them; Phone/scripts/lib/phone_sdk.py refuses an archive that does.
// The Xcode 27.2 SDK itself stays: only it knows iPhone Duo.
extension Date {
    @inline(__always)
    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }

    @inline(__always)
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }
}
