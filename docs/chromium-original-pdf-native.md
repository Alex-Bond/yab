# Original loaded PDF adapter, inactive

`YABCORE_ENABLE_ORIGINAL_PDF` defaults to 0. `nativeOriginalPDF` and its version
remain false/0 unless both this flag and actual experimental SDK v1 exist.
This adapter does not activate the inactive0058 source, change SDK policy,
or establish native compile/runtime acceptance.

The operation captures the existing connected helper actor and its generation,
remote tab, canonical profile, owner Tab object, page operation/document/print
turns before its first await. Every async boundary and final delivery rechecks
that captured endpoint. It never connects, creates a tab, runs script, prints,
reads a URL/file directly, or fetches another copy for a Chromium page.

`page.originalPDF.state {tab,profile,call}` starts one logical lease. Only an
actual SDK state callback can return `{tab,profile,call,lease,nativeAcknowledged:true,
native:{version:1,kind:originalLoadedPDF,operation:state,status:ready,
available:true,complete:false,request,browserId,source,size,rootDocument,
rootFrameId,pdfDocument,pdfFrameId,listener,pluginSource}}`.
State authenticates the original native document/resource at that native
operation, rather than a continuous engine lease or a client URL guess.

`page.originalPDF.export {tab,profile,call,lease,source}` requires the state lease.
The SDK export callback must have a different native request, exactly matching
source/browser/documents/frames/listener/plugin and whole original size1..64MiB.
Only `ready,available:true,complete:true` with an exact-size native binary passes.
Bytes are immutable at the original SDK read ACK. The SDK revalidates original
documents/listener before its delivery. Engine replacement after that ACK is
not represented as continuous original-engine validity.

The helper copies that bounded binary synchronously in the ACTUAL SDK callback.
Neither queued main-queue blocks nor background I/O retains a CEF value across
framework shutdown. A worker owns only independent
Foundation bytes and writes an O_EXCL/O_CLOEXEC0600 descriptor, unlinked before
any bytes are written. Maximum8 leases/one per tab bound retained transfer
memory/files. No PDF filename, native binary object, or whole byte array enters
JSON. `page.originalPDF.read {tab,profile,call,lease}` sends at most196608 bytes
as bounded base64 in the existing JSON wire, with exact offset/size/eof and the
original export receipt. EOF retires the descriptor before the reply. The client
publishes Data only after all chunks and exact whole size validate.

`page.originalPDF.cancel {tab,profile,call}` also works when a state reply/lease
was lost. `page.originalPDF.close` additionally matches lease. Both route before
tab lookup so row destruction cannot prevent cleanup. Original SDK pending RPC
credit/quarantine remains owned by native0058, independent of logical cancellation.
Any native-frame navigation/load, crash, close, detach, disconnect, teardown,
state/export10s, copy15s, or idle30s expiry retires the logical lease. Connection
epoch retires before cleanup; late callbacks cannot write to a replacement peer.
Native late callback logs are distinct from logical helper timeout/retirement.
The client has an overall45s monotonic deadline and never retries unknown.

Tests authored: ChromiumOriginalPDFTests nine controlled receipt/stream cases.
Python source-contract checks are read-only structural/negative checks only.
Required actual acceptance remains NOT_RUN: both API-mode helper compile,
future SDK0058 source compile/link/native tests, signed app, remote/auth/blob
original PDF preservation without second fetch or printing, original buffer
holes, child/foreign PDF rejection, same-document plugin/listener replacement,
state/export/ACK/delivery navigation races, blocked native reply then cancel,
late ACK, helper/browser shutdown and descriptor cleanup. Default-disabled
source cannot claim Fill & Sign parity or native original-PDF acceptance.

## Superseding adapter34 resource ownership

Logical map erasure does not return the work budget. A separate thread-safe
OriginalPDFBudget has8 global credits and one per original tab, including
retired native callbacks, queued UI buffers, utility writers and open FD owners.
Each actual resource owns a shared RAII credit. Byte-buffer credits destruct
after Foundation bytes; file credits destruct after descriptor close. Unknown
or lost callbacks retain credit rather than admitting unbounded retries. Native
callback objects retain their original ticket/credit until actual destruction.
The budget state can outlive its logical wrapper without a raw global lifetime.

YabCore/tests/original_pdf_budget_test.cc exercises the actual production budget
header with delayed callback/writer/file holders, repeated unknown retry, global
limit, concurrent same-owner acquire/release and wrapper destruction. Authored
NOT_RUN. Its small standalone native test is separate from both-API helper
syntax and future original SDK32 runtime acceptance.

Unknown descriptor close or named-file unlink poisons the original shared credit. Capacity remains charged for the helper process lifetime; descriptor close is attempted once. These paths require the combined production C++ budget tests, separately from native PDF-engine acceptance.
