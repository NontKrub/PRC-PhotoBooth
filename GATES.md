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

- [x] G7: GitHub Actions build, test, release, and packaging lanes pass for current source
  EVIDENCE: [PR App Builds run 36217889447](https://github.com/NontKrub/PRC-PhotoBooth/actions/runs/36217889447) ran at implementation SHA a4a0e5156428e430f83d2bab1281d555d6b37f86 and completed successfully. Stable macOS Release/tests, macOS Debug/tests/Release/package, and iPad Simulator Debug/Release/tests/generic Release/package all passed. The prior run 36210283877 failed on the listener-admission timeout; the test wait was raised to 3 seconds without changing the production timeout, and this run passed.

- [ ] G8: the production hardware matrix and sustained event soak pass
  EVIDENCE: Pending physical Mac, Sony ZV-E10, Canon SELPHY CP1500, paired iPad, event network, and 4–6 hour run. Simulator and synthetic tests do not satisfy this gate.

- [ ] G9: browser-driven route discovery and authentication continue through a MainActor stall
  EVIDENCE: Pending production iPad/network integration. Current loopback coverage proves listener admission and cached reconnect socket start; it does not prove browser discovery or initial authentication progress independently of MainActor.

- [ ] G10: paired iPad authenticates after a hostile flood, app restart, and DHCP address change
  EVIDENCE: Pending real listener/iPad integration with stored-secret HMAC verification. Runtime tests prove bounded identity-probe admission and per-ID throttling only.
