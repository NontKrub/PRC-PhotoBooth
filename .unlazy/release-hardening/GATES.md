# Gates: PRC PhotoBooth v1.4.3 release hardening

Scope: close software release-hardening findings A01-A07 and make Event Readiness truthful; retain physical release gates as pending.

- [x] G1: DSLR recovery preserves and validates the failed capture identity through Retry Receive on Xcode 26.6.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/DSLRCaptureAttemptTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: Included in final Mac result bundle /tmp/PRC-PhotoBooth-Mac-Final-2026-09-26.xcresult; full suite summary reports 590 passed, 0 failed, 0 skipped.

- [x] G2: Every requested finalization job is durable, transaction-bound, and recoverable without returning UI to Review.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/FinalizationTransactionTests -only-testing:PRC-PhotoBoothTests/JobQueueStoreTests -only-testing:PRC-PhotoBoothTests/JobRecoveryTests -only-testing:PRC-PhotoBoothTests/SessionRecoveryTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: Included in final Mac result bundle /tmp/PRC-PhotoBooth-Mac-Final-2026-09-26.xcresult; full suite summary reports 590 passed, 0 failed, 0 skipped.

- [ ] G3: The production listener, trusted admission, reconnect, and transport timers remain live during MainActor stalls.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/NetworkRouteTests -only-testing:PRC-PhotoBoothTests/BoothPreAuthPolicyTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: Partial only: final NetworkRouteTests + BoothPreAuthPolicyTests passed twice, including real loopback listener admission and cached reconnect during MainActor stalls. Browser-driven route selection and 100-attempt listener authentication recovery remain open.

- [x] G4: Guest QR endpoint selection fails closed on ambiguity and HTTP admission releases bounded capacity.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/GuestDeliveryEndpointResolverTests -only-testing:PRC-PhotoBoothTests/SessionQRCodePayloadResolverTests -only-testing:PRC-PhotoBoothTests/LocalWebServerTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: Included in final Mac result bundle /tmp/PRC-PhotoBooth-Mac-Final-2026-09-26.xcresult; full suite summary reports 590 passed, 0 failed, 0 skipped.

- [x] G5: Synthetic, hardware, and production soak modes have truthful coverage and cannot report false passes.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/SoakTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: Included in final Mac result bundle /tmp/PRC-PhotoBooth-Mac-Final-2026-09-26.xcresult; full suite summary reports 590 passed, 0 failed, 0 skipped.

- [x] G6: The complete Mac Swift Testing suite passes on the selected Xcode 26.6 local toolchain.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: exit=0; result=Passed; 590 tests, 0 failures, 0 skipped; /tmp/PRC-PhotoBooth-Mac-Final-2026-09-26.xcresult.

- [x] G7: Mac Debug and Release configurations build on Xcode 26.6.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-Mac -destination 'platform=macOS' -derivedDataPath .build/release-hardening -configuration Debug CODE_SIGNING_ALLOWED=NO build && env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-Mac -destination 'platform=macOS' -derivedDataPath .build/release-hardening -configuration Release CODE_SIGNING_ALLOWED=NO build
  EXPECT: BUILD SUCCEEDED
  CWD: .
  EVIDENCE: both commands passed on Xcode 26.6 with CODE_SIGNING_ALLOWED=NO.

- [x] G8: iPad Simulator Debug/Release builds and iPad tests pass on Xcode 26.6.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPad -destination 'platform=iOS Simulator,id=7782B948-224E-4226-B8DD-EB2045862C46' -derivedDataPath .build/release-hardening -configuration Debug CODE_SIGNING_ALLOWED=NO build && env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPadTests -destination 'platform=iOS Simulator,id=7782B948-224E-4226-B8DD-EB2045862C46' -derivedDataPath .build/release-hardening test CODE_SIGNING_ALLOWED=NO && env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPad -destination 'platform=iOS Simulator,id=7782B948-224E-4226-B8DD-EB2045862C46' -derivedDataPath .build/release-hardening -configuration Release CODE_SIGNING_ALLOWED=NO build
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: iPad A16 simulator Debug build, PRC-PhotoBooth-iPadTests, and Release build passed on Xcode 26.6 with CODE_SIGNING_ALLOWED=NO.

- [x] G9: Generic iPadOS Release compilation succeeds on Xcode 26.6.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPad -destination 'generic/platform=iOS' -derivedDataPath .build/release-hardening -configuration Release CODE_SIGNING_ALLOWED=NO build
  EXPECT: BUILD SUCCEEDED
  CWD: .
  EVIDENCE: build passed on Xcode 26.6 with CODE_SIGNING_ALLOWED=NO.

- [ ] G10: Xcode 27 validation.
  EVIDENCE: Not run. Operator selected Xcode 26.6 for local checks; Xcode 27 license remains unaccepted.

- [x] G11: Release-hardening documentation records cause, fix, invariant, automated tests, manual evidence, and honest status for every finding.
  EVIDENCE: Updated tasks/v1.4.3-release-hardening.md with final test/build results and explicit partial A03/A04 status.

- [x] G12: Physical camera, printer, production iPad, multi-interface networking, hostile-client, recovery, and sustained-soak gates are documented and remain explicitly pending until operators run them.
  EVIDENCE: Physical Release Checklist in tasks/v1.4.3-release-hardening.md; physical gates remain pending.

- [x] G13: Affected native Event Readiness UI receives one Impeccable detector pass after implementation.
  CHECK: /Users/nont/.agents/skills/impeccable/scripts/impeccable detect --json Mac/UI/SoakTestSettingsView.swift
  EXPECT: No detector issues found.
  CWD: .
  EVIDENCE: detector exit=0; output [].

<!--
Xcode 27 is installed but its license is currently unaccepted. The operator selected Xcode 26.6 for local checks. G1-G9 are local Xcode 26.6 evidence only and do not satisfy G10. Do not report them as passing on Xcode 27.
-->
