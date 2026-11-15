# Partial native group snapshot transport

This packet extends the disabled original-group helper adapter over public0059 and the library-owned0060 factory. It adds actual drain/seal/capture forwarding and immutable typed snapshot transport. Both accepted versions default to0. Current source62 has neither public contract. No production EngineSwitchAuthority is connected. API-present helper/Swift/native execution is NOT_RUN.

`nativeGroupSnapshots=true/version1` can mean only this partial typed frozen observation. `nativeAtomicSwitchCommit`, `nativeFullMutationFence`, `nativeFullStorageFence` and `nativeMixedWKSwitch` remain false. There is no commit method. A valid snapshot cannot authorize replacing, unloading or retiring an original.

## Original source and one capture

The first authenticated private-socket hello creates one real library-owned CEF owner. Factory-null, later hello, disconnect and replacement peer cannot create or inherit another owner. The snapshot hello additionally retains the helper's actual kernel PID/start sec/usec and a fresh per-original-connection nonce. The client retains that original hello identity; no caller-supplied PID or string owner grants native authority.

The existing immutable ledger holds exact original Tab/profile, browser object/ID, original CefClient, request context/privacy, native primary document and local generation. Each action, capture publication and read delivery repeats original live native-document/client/context checks. The native owner object is supplied directly to public0059, never reconstructed from labels. Every callback must match the original owner/transaction/group/recovery token and ALL original member documents. Native frame processId/routingId are Chromium logical frame identities, not Darwin PIDs/births.

Capture is one-shot per helper group, admitted before the actual SDK call. Its actual native UI callback synchronously reads/serializes the CEF result exactly once. No CEF dictionary/string/reference crosses into writer/reader work. The independent UTF8 bytes contain the entire native envelope, all exact native frame identities and native fixed-state results. There is no page JS/DOM counter, URL inference, recapture, truncation or synthetic callback. Metadata is checked against the original ledger and captured topology before writing.

The transport caps the COMPLETE UTF8 callback envelope at16MiB. Current native producer caps state bytes at16MiB before envelope overhead; a legal extreme can therefore be rejected whole. Producer envelope-budget alignment is an active acceptance requirement. Refusal never produces a partial snapshot or a successful switch.

## Immutable storage and lifetime budget

`group_snapshot_store.h` is independent of CEF. A shared RAII credit admits at most two global capture groups and one capture per group. The original ledger retains its credit until an actual native `recoveryRetired=true/processOwned=false` acknowledgment. This accounts for the native registry's retained captured state, including unknown/cancelled operations. Callback, independent buffer, queued writer, readonly file and reader also retain the same credit. Native callback destruction defers its credit release beyond the SDK callback stack's resource cleanup.

Removing a local stream discovery entry, client cancellation, native cancel dispatch, timeout or disconnect does not refund any of these holds. The last real resource release can refund once only after the native registry hold is gone. A close/unlink uncertainty permanently poisons that finite slot until helper exit. No eviction creates new capacity. A completed timer or callback may conservatively retain capacity longer; it cannot release it early.

A fresh random O_EXCL/O_NOFOLLOW/CLOEXEC file is created0600. The writer verifies the regular inode, UID, mode and initial link count, opens a separate readonly descriptor for the same inode, then unlinks BEFORE writing any source byte and verifies nlink0. Writes are bounded/EINTR-aware and cancellation-aware. fsync and exact final size precede closing the only writable descriptor. Only the readonly FD is published; no writable API or pathname survives. Anonymous fsync is not a durable recovery journal. Read errors or canceled readers cannot publish bytes.

## Wire contract, unchanged4MiB socket

Original helper hello: `nativeGroupSource:{helperPID,helperBirthSec:string,helperBirthUsec,connection,helperOwner}` only when the actual partial snapshot capability exists.

A successful native capture response contains its exact metadata receipt and a descriptor:

- version1, stream, original client transaction and captureCommand;
- total1..16777216, sha256 of the entire frozen native UTF8 envelope;
- maxChunk196608, immutable=true, partial=true, commitAvailable=false, nativeAtomicSwitchCommit=false;
- original helper PID/birth, original connection/owner, native transaction/group/recovery token/seal/snapshot, all member tab/profile/native browser/document mappings;
- base64 source identity bytes and sourceSHA256. That identity repeats the ownership keys and every original native frame's browserId/processId/routingId/document/main plus parent process/routing pair for subframes. URLs never grant source admission; they remain bound by the full payload digest.

The source and descriptor are each separately bounded before queueing a writer. Source metadata has no raw field/storage payload. The whole native payload remains inside the anonymous FD and the receiving client's memory, never logs.

`switch.group.snapshot.read {descriptor,offset,length}` requires the EXACT complete descriptor and original live peer. length is1..196608 and offset/range must fit total. At most one read per stream is in flight. Reply: exact descriptor, exact offset, actual length, SHA256 of that chunk and canonical base64 data. Read completion checks the original native source AGAIN before replying. EOF/replacement peer receives no old async reply.

`switch.group.snapshot.release {descriptor}` drops only local stream discovery, returns released=true/nativeReleased=false. It never releases native reservations or credits by itself. Subsequent native mutations invalidate discovery, but do not fabricate source cancellation or native retirement.

Explicit same-helper inspect/inspect-owner can discover a ready frozen descriptor after a lost capture reply. It does not perform a second capture. Timed-out/uncertain/detached source cannot become a ready original through a late callback. Missing descriptor is unknown. Only the original process-owned actual owner object can query its own registry.

Swift `NativeGroupSnapshotDescriptor` and the reusable Python receiver validate original-hello PID/birth/connection, original group/member/frame topology, all range/digest/base64 fields and the final complete envelope. Parent topology must be acyclic, complete and within each original browser. Fixed-state validation keeps local/session null versus arrays, unique storage keys, finite scroll, form index/type/tag/selected null-versus-list and native secret-type exclusions. This remains the native fixed portable subset, not full profile/storage/JS-heap transfer. The receiver performs only sequential read requests; loss is unknown, with no retry/reconnect/cancel/retire/release side effect.

## Explicit loss and verification limits

The original-group helper's current R1 EOF/parent-death policy can terminate the helper. Source-process loss destroys the owner/registry and anonymous FD; original documents cannot be promised alive. The original process-owned receipt is not durable storage. Neither a PID/string ID nor a newly created factory owner can recover the old actual authority. Unknown remains quarantine, not retained or closed.

Executed for this packet: seven actual Python receiver boundary tests and five existing adapter source/negative guards. Authored NOT_RUN: five controlled Swift typed-receiver tests and standalone C++ actual RAII/anonymous-FD tests. No native compilation/runtime/job occurred. Required next proof uses one exact future signed helper/SDK in both API modes, original quiet/sticky/all-frame/OOPIF capture and resource fault boundaries, original peer loss, late callback and ordered native retirement. Full commit, mutation/storage fences, mixed WK and durable recovery remain separate blockers.
