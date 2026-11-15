import Testing
@testable import Fast

/// A password manager comes in pinned the first time only (Extensions.pinsOnArrival).
@Suite
struct ExtensionPinTests {
    static let bitwarden = "nngceckbapebfimnlniiiahkandclblb"

    @Test func aPasswordManagerIsPinnedTheFirstTime() {
        #expect(Extensions.pinsOnArrival(Self.bitwarden, pinnedBefore: []))
        for id in Extensions.passwordManagers {
            #expect(Extensions.pinsOnArrival(id, pinnedBefore: []))
        }
    }

    @Test func neverAgainOncePinned() {
        // Unpinned by hand, or removed and added again: Yab has pinned it
        // before, and leaves it as the person did.
        #expect(!Extensions.pinsOnArrival(Self.bitwarden, pinnedBefore: [Self.bitwarden]))
        // Another one pinned before doesn't count against it.
        #expect(Extensions.pinsOnArrival(Self.bitwarden, pinnedBefore: ["aeblfdkhhhdcdjpifhhbdiojplfjncoa"]))
    }

    @Test func othersComeInAsBefore() {
        #expect(!Extensions.pinsOnArrival("cjpalhdlnbpafiamejdnhcphjbkeiagm", pinnedBefore: [])) // uBlock Origin
        #expect(!Extensions.pinsOnArrival("local-1a2b3c4d", pinnedBefore: []))
    }

    @Test func knownIDsAreStoreIDs() {
        #expect(Extensions.passwordManagers.count == 9)
        for id in Extensions.passwordManagers {
            #expect(id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) })
        }
    }
}
