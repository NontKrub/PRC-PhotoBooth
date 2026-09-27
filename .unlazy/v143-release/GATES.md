# Gates: PRC PhotoBooth v1.4.3 release hardening

OWNS: Mac/**, Shared/**, Tests/**, GATES.md, README.md

Scope: close software release blockers, verify regressions, and report physical gates truthfully.

- [ ] G1: cloud QR, publish alias, verification URL, and cleanup alias use one route authority
  CHECK: node /Users/nont/.agents/skills/unlazy/scripts/gate-check.mjs --root . --cwd . --reverify .unlazy/v143-release/gates/leaf-1.1.1.md
  EXPECT: ALL MET
  EVIDENCE: pending

- [ ] G2: active soak sessions do not enter normal local routes or customer gallery
  CHECK: node /Users/nont/.agents/skills/unlazy/scripts/gate-check.mjs --root . --cwd . --reverify .unlazy/v143-release/gates/node-1.1.md
  EXPECT: ALL MET
  EVIDENCE: pending

- [ ] G3: SwiftData origin, run, and cycle metadata isolate soak from normal history and statistics
  EVIDENCE: pending

- [ ] G4: cleanup is idempotent, hides exposure before deleting artifacts, and preserves retry diagnostics
  EVIDENCE: pending

- [ ] G5: selected network interface resolution stays fail-closed while unrelated conflicts do not block a valid selection
  EVIDENCE: pending

- [ ] G6: Event Readiness copy/progress/coverage accurately reports isolation, QR verification, cleanup warnings, and subsystem state
  EVIDENCE: pending

- [ ] G7: A01, A02, legacy side effects, A05-A08, and physical print unknown-side-effect regressions pass
  CHECK: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/DSLRCaptureAttemptTests -only-testing:PRC-PhotoBoothTests/FinalizationTransactionTests -only-testing:PRC-PhotoBoothTests/SessionRecoveryTests -only-testing:PRC-PhotoBoothTests/GuestDeliveryEndpointResolverTests -only-testing:PRC-PhotoBoothTests/NetworkRouteTests -only-testing:PRC-PhotoBoothTests/LocalWebServerTests -only-testing:PRC-PhotoBoothTests/PrinterServiceTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'PRESERVED_REGRESSIONS_PASSED\n'
  EXPECT: PRESERVED_REGRESSIONS_PASSED
  EVIDENCE: pending

- [ ] G8: full local Xcode 27 macOS and iPad build/test matrix passes
  EVIDENCE: pending

- [ ] G9: GitHub Actions Xcode 27 and stable macOS lanes pass at final SHA
  EVIDENCE: pending

- [ ] G10: 500+ production sessions and 4-6 hour physical/network/camera/print/crash matrix pass
  EVIDENCE: pending

- [ ] G11: required final report reconciles every software and physical gate with current evidence
  EVIDENCE: pending
