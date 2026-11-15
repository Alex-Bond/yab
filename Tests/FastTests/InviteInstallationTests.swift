import Foundation
import Testing
@testable import Fast

/// Existing UUID persistence only: memory adapters, no Keychain or allocation.
@MainActor
struct InviteInstallationTests {
    private static let original = "00000000-0000-4000-8000-000000000444"
    private static let another = "00000000-0000-4000-8000-000000001371"
    private static let fresh = "00000000-0000-4000-8000-000000001513"

    private final class Memory {
        var saved: String?
        var backup: Invites.InstallationBackup = .missing
        var kept: [String] = []
        var makes = 0
        var locks = 0
        var inLock = false
        var keepSucceeds = true

        var storage: Invites.InstallationStorage {
            .init(read: { #expect(self.inLock); return self.saved },
                  save: { #expect(self.inLock); self.saved = $0 },
                  backup: { #expect(self.inLock); return self.backup },
                  keep: {
                      #expect(self.inLock)
                      self.kept.append($0)
                      if self.keepSucceeds { self.backup = .found($0) }
                      return self.keepSucceeds
                  },
                  make: { #expect(self.inLock); self.makes += 1; return InviteInstallationTests.fresh },
                  locked: { body in
                      #expect(!self.inLock)
                      self.inLock = true
                      self.locks += 1
                      defer { self.inLock = false }
                      body()
                  })
        }
    }

    @Test func anInstalledCopyKeepsItsPreferencesAndBackfillsItsExistingID() {
        let memory = Memory()
        memory.saved = Self.original
        memory.backup = .found(Self.another)
        #expect(Invites.installation(using: memory.storage) == Self.original)
        #expect(memory.saved == Self.original)
        #expect(memory.kept == [Self.original], "an update must backfill the existing UUID, never adopt another owner")
        #expect(memory.makes == 0)
    }

    @Test func aDataReinstallRecoversTheSameUUIDWithoutAllocatingAnother() {
        let memory = Memory()
        memory.backup = .found(Self.original)
        #expect(Invites.installation(using: memory.storage) == Self.original,
                "a data reinstall must recover the persisted installation UUID")
        #expect(memory.saved == Self.original)
        #expect(memory.makes == 0)
    }

    @Test func aFreshInstallCreatesOneIDThatSurvivesSettingsRemoval() {
        let memory = Memory()
        #expect(Invites.installation(using: memory.storage) == Self.fresh)
        memory.saved = nil
        #expect(Invites.installation(using: memory.storage) == Self.fresh)
        #expect(memory.makes == 1, "a reinstall must not create a second ID")
        #expect(memory.locks == 2)
    }

    @Test func anUnavailableBackupDoesNotAllocateAnID() {
        let memory = Memory()
        memory.backup = .unavailable
        #expect(Invites.installation(using: memory.storage) == nil,
                "an unavailable keychain must not silently create another identity")
        #expect(memory.saved == nil)
        #expect(memory.kept.isEmpty)
        #expect(memory.makes == 0)
    }

    @Test func unlockingTheBackupAllowsTheNextResolutionToRecover() {
        let memory = Memory()
        memory.backup = .unavailable
        _ = Invites.installation(using: memory.storage)
        memory.backup = .found(Self.original)
        #expect(Invites.installation(using: memory.storage) == Self.original,
                "a retry after unlock must recover the original UUID")
        #expect(memory.makes == 0)
    }

    @Test func unavailableBackupCannotReplaceValidPreferences() {
        let memory = Memory()
        memory.saved = Self.original
        memory.backup = .unavailable
        memory.keepSucceeds = false
        #expect(Invites.installation(using: memory.storage) == Self.original)
        #expect(memory.saved == Self.original)
        #expect(memory.makes == 0)
        memory.keepSucceeds = true
        #expect(Invites.installation(using: memory.storage) == Self.original)
        #expect(memory.kept == [Self.original, Self.original])
    }

    @Test func malformedPreferencesRecoverAValidBackup() {
        for value in ["", "not-a-uuid"] {
            let memory = Memory()
            memory.saved = value
            memory.backup = .found(Self.original)
            #expect(Invites.installation(using: memory.storage) == Self.original)
            #expect(memory.saved == Self.original)
            #expect(memory.makes == 0)
        }
    }

    @Test func malformedBackupDoesNotInventAnIdentity() {
        let memory = Memory()
        memory.backup = .found("not-a-uuid")
        #expect(Invites.installation(using: memory.storage) == nil)
        #expect(memory.saved == nil)
        #expect(memory.makes == 0)
    }
}
