# Gates: v1.4.3 Settings and iPad connectivity remediation

Scope: implement and verify the current settings, secure control, and reconnect presentation blockers on Xcode 26.6.0.

- [ ] G1: the exact first malformed control frame and state are named from a reproducible trace or safe production diagnostic
  EVIDENCE: Still pending. The supplied brief identifies only the symbolic `malformedEnvelope` symptom; it contains no captured frame, inbound message case, timestamped diagnostics export, or populated incident log. The new diagnostics are ready to capture this on a reproducing device.

- [x] G2: security review finds no plaintext downgrade, replay reset, stale-generation mutation, or secrets in diagnostics
  EVIDENCE: Independent source review found no remaining issue after the authentication phase-order guards; all 13 review questions are recorded in `reviews/final.md`. Parser tests verify symbolic, payload-redacted metadata; full Mac tests and the stored-secret/hostile-client route tests pass.

- [ ] G3: Settings and reconnect presentation pass minimum-size, resize, localization, and transient-discovery review
  EVIDENCE: Source audit, localization/presentation tests, and the Impeccable detector pass. Built Settings screenshots at the requested sizes and rendered Thai geometry were not captured; physical 9.7-inch layout is also pending.

- [x] G4: relevant Xcode 26.6.0 Mac and iPad builds and automated suites pass
  EVIDENCE: Xcode 26.6 (build 17F113), selected from `/Applications/Xcode-26.6.0.app/Contents/Developer`: Mac Debug/Release and iPad generic Simulator Debug/Release builds passed; full Mac suite passed 672, skipped 13, failed 0; iPad simulator suite passed 23/23; framing suite passed 24/24. Network route and presentation suites also passed (50 passed, 13 skipped).

- [ ] G5: physical iPad Pro 9.7-inch, hotspot/router, restart, foreground recovery, and soak validation completes
  EVIDENCE: Pending operator validation. The only available simulator is an iPad Pro 13-inch on iOS 26.5; the named iPad Pro 9.7-inch / iPadOS 16.7.16 device is not connected. No router/hotspot, restart, foreground recovery, or physical soak was claimed.
