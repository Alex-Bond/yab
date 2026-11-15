# Sync contract fixtures

`vectors-v1.json` contains deterministic test keys and nonces. They must never be
used for a real account. `generate.mjs` uses Node's independent crypto provider
to exercise the format from `Sources/SyncKit/Seal.swift`: account/auth HKDF,
record names and AES-GCM AAD, recovery checksum, inner Wallet secrets, pairing
v2 PBKDF2/tagged X25519 and its envelope. Kotlin contract tests consume this file.

`approval-vectors-v1.json` separately binds request facts and full details. It
exercises `seen` exclusion, omitted optional nulls, unknown nested properties,
full mail/bcc/payment objects, slash/control/Unicode escaping, fractional and
integral numbers, an exponent and negative zero. Kotlin preserves the numeric
tokens in Swift's canonical wire bodies instead of formatting them as JVM
Doubles. A numeric value created by an unrelated noncanonical JSON producer is
not an interoperability guarantee.

The Swift harness compiles the production Request/Detail models and encoder,
then verifies exact canonical bytes and SHA-256. Its support file substitutes
only three collection-name constants. It always saves actual Swift output to
the farm result folder before comparing, so a mismatch is inspectable. Run the
complete harness through the shared farm:

```sh
bash Android/scripts/core-check.sh
```

Generate fixtures with `node SharedContracts/sync/generate.mjs` and
`node SharedContracts/sync/generate-approvals.mjs`. Any changed
crypto output must pass both Swift and Kotlin verification before acceptance.
JSON object key order is not a requirement for encrypted records; decrypting
must yield the same typed record. Digests for assistant approvals are separate
protocols and require their documented canonical JSON.

`task-vectors-v1.json` adds three production `TaskRecords.Request` and
`Observation` cases: omitted/null optionals, public-space read-only epoch,
and an exact tab source with fractional `created`, Unicode and a revision
larger than UInt32. `generate-tasks.mjs` creates synthetic facts; the same
standalone Swift oracle compiles the real TaskRecords/OpenOnMac sources,
validates the models and verifies exact canonical bytes and request digests.
`TaskSupport.swift` substitutes only unused client/journal IO surfaces, which
trap if called. It does not substitute wire models, URL checks or encoding.
Android authors task creation times as whole Unix seconds to avoid introducing
a JVM-specific Double exponent spelling into its own request digest.

`core-check.sh` writes `verify-sync`, `approval-vectors-swift.json`, `task-vectors-swift.json`, and
`core-test-results/test/TEST-*.xml` directly into `$YAB_FARM_OUT`. When called by
`worker-check.py`, its console output is also retained in `swift-crypto.log`.
These vectors cover wire cryptography and Codable approval facts. Apple device
registration, classification, capability stamps and handoff consumers need the
existing Swift integration suites separately, after the Android APK is green:

```sh
./farm exec --low --name 'Android Sync compatibility' --estimate 600 --timeout 1800 -- \
  bash Android/scripts/swift-compat-check.sh
```

That helper selects `AndroidSyncCompatibilityTests`, `SyncClientTests`,
`SyncPhoneTests`, `PhoneFrontTests`, `TaskLaunchTests`, `TaskObservationTests`,
and `RemoteTaskReadTests`. It retains `filter.txt`, `snapshot`, `test.log`,
`events.jsonl` and `results.xml` under `$YAB_FARM_OUT/swift-compat/` and refuses
an empty passing test selection. It neither runs the Worker suites again nor
publishes a backend. The iOS `PhoneSync` adapter still needs its own simulator
compile/unit check; the standalone Swift crypto oracle does not compile UIKit.
