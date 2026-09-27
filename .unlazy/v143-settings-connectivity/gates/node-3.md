# Gates: integrated release verification

Scope: verify the final remediation on Xcode 26.6.0 and record physical gates honestly.

- [ ] N1: all implementation child ledgers are reverified and their leases are released
  EVIDENCE: Automated implementation gates are reverified. Child gates remain open for the exact incident frame, rendered Settings checks, and physical iPad validation.

- [ ] N2: actual first invalid control frame, receiver role, generation, and protocol phase are recorded
  EVIDENCE: Pending because the supplied incident material contains no captured frame or diagnostic export. Current synthetic loopback traces test protocol states but are not the production incident.

- [x] N3: Mac Debug/Release, iPad Simulator Debug/Release/tests, and affected network suites pass on Xcode 26.6.0
  EVIDENCE: Xcode 26.6 build 17F113. Mac Debug/Release and iPad generic Simulator Debug/Release builds passed. Complete Mac suite: 672 passed, 13 skipped, 0 failed. iPad suite: 23 passed, 0 failed. Affected connectivity suite: 115 passed, 13 skipped; the post-addition framing suite: 24 passed.

- [x] N4: independent final security and ponytail review finds no actionable defect
  EVIDENCE: Independent review found one P2 phase-order issue, which was fixed with mutual-authentication guards before secure Hello/Ready handling, establishment, and promotion. Loopback regression now covers premature Hello and Ready; review addendum is in `reviews/final.md`. No remaining actionable source finding.

- [ ] N5: physical iPad Pro 9.7-inch and event network validation completes or remains an explicit operator handoff
  EVIDENCE: Explicit operator handoff remains: physical iPad Pro 9.7-inch / iPadOS 16.7.16, router and iPad hotspot topologies, restarts, foreground recovery, and long-duration soak remain required.
