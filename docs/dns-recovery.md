# DNS outage recovery (request 2021 / feedback 1636)

The report is from 0.45.1, macOS 27.2, MacBookAir10,1, 26 tabs (4 loaded).
Its fourteen failures are NSURLErrorDomain/-1003 (WebKit), not Chromium
net/-105. It supplies neither a failing hostname nor resolver/proxy settings.
The reporter's underlying network failure is therefore not established.

Inspection of the 0.46.11 tree found no app-selected DoH server, secure DNS
mode, global proxy/PAC or IPv4-only resolver switch. Chromium keeps its own
network policy, system configuration and extension proxy handling. WebKit's
extension proxy implementation is separate (`ExtensionProxy.swift`). Nothing
in this change changes resolver, proxy, certificate or address-family policy.

ChromiumProcess deliberately passes `--disable-auto-reload`, to keep ordinary
connection errors from producing hidden reload loops. That also stops Chrome's
DNS recovery. The candidate adds three bounded retries of a failed HTTP(S)
GET at 1, 5 and 60 seconds after successive DNS failures. It neither remembers
negative DNS answers nor flushes Chrome's cache. Non-DNS failures remain stopped.
New accepted navigations, Stop, page retirement and helper loss cancel the
pending retry; forms are excluded. The final delay allows Chrome's own negative
cache time to elapse. A longer outage still requires explicit Reload.

`DNSRetryTests` covers error filtering, exact URL identity, duplicate failures,
finite budgets, resets, and unsafe requests. `ChromiumLoadFailureTests` retains
the engine callback/error-domain tests. `evals/golden/dns_recovery.py` supplies
an isolated local DoH resolver returning SERVFAIL, then loopback A records,
and checks that the document really loads. It refuses a pass if the local
resolver wasn't used or the first error wasn't DNS. The baseline additionally
checks that explicit Reload works after DNS recovery. TLS bypass and proxy
bypass exist only in the isolated test process, never in product settings.

The fixture is registered on `qa/pending/dns-recovery.json`. Download and run
the published 0.46.11 inside a display farm job with
`bash qa/checks/dns_published.sh`; the candidate probe accepts a prepared app
and never builds it. No reporter-profile acceptance is implied by this fixture.
