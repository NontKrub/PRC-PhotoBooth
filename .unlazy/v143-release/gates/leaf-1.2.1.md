# Gates: A03/A04 transport liveness and trusted admission

OWNS: Shared/Connectivity/**, Tests/NetworkRouteTests.swift, Tests/BoothPreAuthPolicyTests.swift, Tests/BoothPairingTests.swift

Scope: give the control transport one authority that progresses trusted authentication, secure bootstrap, and bounded reconnect independently of MainActor and anonymous slot occupancy.

- [ ] G1: trusted HMAC probe lane succeeds after anonymous flood, active anonymous occupancy, restart, and endpoint change; spoofed IDs are throttled
  CHECK: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/NetworkRouteTests -only-testing:PRC-PhotoBoothTests/BoothPreAuthPolicyTests -only-testing:PRC-PhotoBoothTests/BoothPairingTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TRUSTED_ADMISSION_TESTS_PASSED\n'
  EXPECT: TRUSTED_ADMISSION_TESTS_PASSED
  EVIDENCE: pending

- [ ] G2: production Hello, HMAC, secure channel, heartbeat, browser route discovery, and reconnect finish while MainActor is blocked
  EVIDENCE: pending
