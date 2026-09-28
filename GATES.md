# Gates: PRC PhotoBooth v1.4.3 release hardening

OWNS: Mac/**, Shared/**, Tests/**, tasks/**

Scope: fix the confirmed route crash and remaining software release blockers, verify regressions, and report CI and physical-event gates truthfully.

- [x] G1: duplicate path interfaces merge deterministically and conflicting routes fail closed
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/GuestDeliveryEndpointResolverTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=ad70b618cc8f67fe4de8cdd0469ae45a15e0ac5b2c8a571c53d73491f92cd5ef; exit=0; EXPECT=matched; output-sha256=93a22671f8161c9dfcc38e41625427efe6d689f2a794ce9324c48e34dc46f519; output-bytes=620; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [x] G2: legacy finalization does not inherit current print or cloud settings
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/SessionRecoveryTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=df91e7f5d6fc5fa148a72f3cc55fd3f98944cd82ac1575478a88ab46ebc83bf8; exit=0; EXPECT=matched; output-sha256=70953154be0924caed14339fe2012578d9543ca4085c1752d68036d44a14a112; output-bytes=620; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [x] G3: camera recovery preserves freshness and only resets PTP quarantine after a trusted reconnect baseline
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/DSLRCaptureAttemptTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=8c810b43208f6e970f10c4d980a381d0990216cf440befe2d2c659709341a997; exit=0; EXPECT=matched; output-sha256=1694b26acdd8b6795af200e999bdf2976e954aee38af2c260bdb4f0420075d10; output-bytes=620; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [x] G4: queue-owned listener, reconnect, and pre-auth regression tests pass
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/NetworkRouteTests -only-testing:PRC-PhotoBoothTests/BoothPreAuthPolicyTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=5879a22af61cccb76da343b5064ed2c96e6b6cba84b855df9c719f57403ab7d8; exit=0; EXPECT=matched; output-sha256=5bcb06e90239b912d125a5af65a6c06ec114e0d6842fb352f113b6bd2fe1b6c2; output-bytes=623; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [x] G5: failed soak sessions cannot remain guest-visible and cloud soak output is isolated
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/SoakTests -only-testing:PRC-PhotoBoothTests/CloudUploadServiceTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=504fefb2cd3ad0ab12a275ef53ac543abb35c762d063d10ca3db19b4ee3b8b93; exit=0; EXPECT=matched; output-sha256=b514f796f0b0dae9bed8bee75eebd89ebe8ca5897edba7d7576d0c5ebb1370fc; output-bytes=620; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [x] G6: the complete Mac test suite passes
  CHECK: DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: automatic-evidence=v1; definition-sha256=f7324877838d588c4b34ace05a2de7cbc45c690b97b3ef5da0026524eaa5ca66; exit=0; EXPECT=matched; output-sha256=1dd6495bfc4544022a09bc98a721e653082b1be6c3785bb90894f37b7962d95a; output-bytes=623; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries

- [ ] G7: GitHub Actions build, test, release, and packaging lanes pass for the candidate source
  EVIDENCE: Historical [PR App Builds run 36217889447](https://github.com/NontKrub/PRC-PhotoBooth/actions/runs/36217889447) passed at SHA a4a0e5156428e430f83d2bab1281d555d6b37f86. Branch tip 00e59690839d31a7036e916e3195b40170696ffe failed [run 36324733379](https://github.com/NontKrub/PRC-PhotoBooth/actions/runs/36324733379) only in the isolated MainActor stall test; its iPad lanes passed. Remediation passed local verification, but the new PR candidate still needs its own remote CI result.

- [ ] G8: the production hardware matrix and sustained event soak pass
  EVIDENCE: Pending physical Mac, Sony ZV-E10, Canon SELPHY CP1500, paired iPad, event network, and 4–6 hour run. Simulator and synthetic tests do not satisfy this gate.

- [ ] G9: browser-driven route discovery and authentication continue through a MainActor stall
  EVIDENCE: Pending production iPad/network integration. Current loopback coverage proves listener admission and cached reconnect socket start; it does not prove browser discovery or initial authentication progress independently of MainActor.

- [ ] G10: paired iPad authenticates after a hostile flood, app restart, and DHCP address change
  EVIDENCE: Pending real listener/iPad integration with stored-secret HMAC verification. Runtime tests prove bounded identity-probe admission and per-ID throttling only.

- [x] G11: authenticated control traffic and liveness remain active during the exact 12-second MainActor stall
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' TEST_RUNNER_PRC_RUN_MAINACTOR_STALL_TESTS=1 /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers -only-testing:'PRC-PhotoBoothTests/NetworkRouteTests/authenticatedControlTrafficSurvivesTwelveSecondMainActorStall()' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Baseline reproduced on Xcode 26.6: activityCount=1, timeoutCount=1, transportClosedCount=1. Final full Mac run passed the repaired test: 698 passed, 0 failed, 0 skipped in `.build/final-blockers/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.27_23-09-25-+0700.xcresult`.

- [x] G12: queue-owned control delivery preserves order, enforces bounded backpressure, and rejects stale generations
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' TEST_RUNNER_PRC_RUN_MAINACTOR_STALL_TESTS=1 /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers -only-testing:PRC-PhotoBoothTests/NetworkRouteTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Final full Mac run passed the 12-second ordering/backpressure, stale-generation, and real direct-frame overflow tests: `.build/final-blockers/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.27_23-09-25-+0700.xcresult` (698 passed, 0 failed, 0 skipped). The isolated stall and listener-admission tests also passed in the final serial rerun.

- [x] G13: PIN Keychain lookup distinguishes absent, inaccessible, and malformed credentials without destructive migration
  CHECK: DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers -only-testing:PRC-PhotoBoothTests/KeychainHelperTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Final full Mac run passed `KeychainHelperTests`, including found/notFound/unavailable/malformed and non-destructive migration cases: `.build/final-blockers/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.27_23-09-25-+0700.xcresult` (698 passed, 0 failed, 0 skipped).

- [x] G14: pairing secrets preserve trusted metadata on Keychain failures and remain readable from the supported store
  CHECK: DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers -only-testing:PRC-PhotoBoothTests/BoothPairingTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Final full Mac run passed `BoothPairingTests`, including unavailable-store metadata preservation, dual-store conflict preservation, and failed Data Protection write consistency: `.build/final-blockers/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.27_23-09-25-+0700.xcresult` (698 passed, 0 failed, 0 skipped).

- [x] G15: PIN gate and Settings strings have English and Thai translations
  CHECK: DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers -only-testing:PRC-PhotoBoothTests/LocalizationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Localization tests and English/Thai catalog checks passed in the final Mac suite: `.build/final-blockers/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.27_23-09-25-+0700.xcresult` (698 passed, 0 failed, 0 skipped). Rendered Settings/PIN screenshots, accessibility inspection, and Thai geometry review are tracked in G18.

- [x] G16: full Mac and iPad simulator test suites pass on the available Xcode 26.6 toolchain
  CHECK: DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/final-blockers CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPadTests -destination 'platform=iOS Simulator,name=iPad Pro 13-inch' -derivedDataPath .build/final-blockers CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'TESTS_PASSED\n'
  EXPECT: TESTS_PASSED
  EVIDENCE: Latest Mac suite: 700 tests passed, 0 failed, 0 skipped, `.build/current-fixes/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.28_08-41-32-+0700.xcresult`; its dynamic parameter runs total 704. The two new timer/core teardown tests also passed after the final source edit in `.build/current-fixes/Logs/Test/Test-PRC-PhotoBoothTests-2569.09.28_08-46-56-+0700.xcresult`. Latest iPad simulator suite: 23 passed, 0 failed, 0 skipped, `.build/ipad-current-fixes/Logs/Test/Test-PRC-PhotoBooth-iPadTests-2569.09.28_08-40-24-+0700.xcresult`. Mac Release and generic iPadOS Release builds exited 0 after the final source edit; Debug builds were exercised by their test suites. Xcode 26.6 was used.

- [x] G17: effective built-app signing identity and entitlements explain the actual credential persistence behavior
  EVIDENCE: Signed Debug and Release app products report bundle `com.nont.prcphoto.mac`, Apple Development signing, a matching `application-identifier` and team-prefixed `keychain-access-groups` shape (`<TEAMID>.com.nont.prcphoto.mac`); both configurations use identical values. The opt-in dedicated test service write passed in a signed Debug test host, read passed after a clean Debug rebuild and from a Release-config test host, and cleanup passed. The Team ID was supplied only as a local command-line build override. The probe never used the production Admin PIN service.

- [ ] G18: built Settings scene shows the full PIN gate and all eight categories at required sizes in English and Thai
  EVIDENCE: pending rendered screenshots and accessibility inspection.

- [ ] G19: physical iPad matrix, rebuild persistence, and sustained event soak pass
  EVIDENCE: On 2026-09-28 the operator reported physical iPadOS 16.7.16 connection over home Wi-Fi and iPad hotspot, QR pairing, and a Sony ZV-E10 session connection to the Mac. Camera capture was not tested. Changing Mac Wi-Fi triggered a transport-queue assertion; the iPad log then recorded heartbeat timeout and repeated control deadlines. The route-change and Forget All fixes still require physical retesting, as do camera capture, printer, and the 30-minute minimum soak.
