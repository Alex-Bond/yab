import Foundation
import Testing
@testable import Fast

/// Pages see passkeys by the person's switch and what this build can do,
/// never by a false a capability-less launch wrote and Sync carried
/// (#1936, #1944: Apple's sign-in asked for a newer browser).
@Suite(.serialized)
@MainActor
struct PasskeyOfferTests {
    private let keys = ["passkeys", "passkeys.entitled", Preferences.passkeysKey]

    private func keeping(_ body: () throws -> Void) rethrows {
        let store = Store.settings
        let kept = keys.map { store.object(forKey: $0) }
        let offered = FormRelay.passkeysOffered
        defer {
            for (key, value) in zip(keys, kept) {
                if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
            }
            FormRelay.passkeysOffered = offered
        }
        keys.forEach(store.removeObject(forKey:))
        try body()
    }

    /// What a Mac holds after a launch without the entitlement wrote false,
    /// or Sync brought one in: the upgrade offers passkeys again.
    @Test func aPoisonedStoreOffersPasskeysOnAMacThatCan() {
        keeping {
            let store = Store.settings
            store.set(false, forKey: "passkeys")
            store.set(true, forKey: "passkeys.entitled")
            #expect(Preferences.passkeysOn(in: store))
            #expect(Preferences.offersPasskeys(in: store, possible: true))
            #expect(Preferences().passkeys)
            // Without the capability nothing is offered, whatever the switch.
            #expect(!Preferences.offersPasskeys(in: store, possible: false))
        }
    }

    /// Turned off by the person after the upgrade: off it stays, launch
    /// after launch, and it goes to their other Macs by its own key.
    @Test func aPersonsOffStaysOff() {
        keeping {
            let prefs = Preferences()
            #expect(prefs.passkeys)
            prefs.passkeys = false
            #expect(Store.settings.object(forKey: Preferences.passkeysKey) as? Bool == false)
            #expect(!Preferences().passkeys)
            #expect(!Preferences.offersPasskeys(in: Store.settings, possible: true))
            #expect(SyncShapes.syncs(Preferences.passkeysKey))
        }
    }

    /// A Mac without the capability (this test process has no entitlement,
    /// as an older or a development build) writes nothing for others to
    /// take, and what such a Mac sent as "passkeys" never syncs in.
    @Test func aMacWithoutTheCapabilityTurnsNoMacOff() {
        keeping {
            let prefs = Preferences()
            #expect(!prefs.passkeysPossible)
            FormRelay.passkeysOffered = false
            #expect(Store.settings.object(forKey: Preferences.passkeysKey) == nil)
            #expect(Store.settings.object(forKey: "passkeys") == nil)
            #expect(!SyncShapes.syncs("passkeys"))
            // Its old key arriving anyway changes nothing here.
            Store.settings.set(false, forKey: "passkeys")
            #expect(Preferences.offersPasskeys(in: Store.settings, possible: true))
        }
    }
}
