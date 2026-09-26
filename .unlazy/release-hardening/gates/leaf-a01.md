# Gates: A01 DSLR capture privacy

OWNS: Mac/Camera/**, Mac/Capture/CaptureService.swift, Mac/UI/BoothCoordinator.swift, Tests/DSLRCaptureAttemptTests.swift

Scope: Preserve the failed shutter attempt through Retry Receive and authorize every incoming camera media source against the same identity and freshness proof.

- [x] G1: DSLR capture privacy lifecycle tests pass with Xcode 26.6.
  CHECK: env DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer' /Applications/Xcode-26.6.0.app/Contents/Developer/usr/bin/xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath .build/release-hardening -only-testing:PRC-PhotoBoothTests/DSLRCaptureAttemptTests test CODE_SIGNING_ALLOWED=NO
  EXPECT: TEST SUCCEEDED
  CWD: .
  EVIDENCE: automatic-evidence=v1; definition-sha256=0194e412ef4e510061437dd5ecf01d295ba9c18b6a1450c5cbbfdad155861a6f; exit=0; EXPECT=matched; output-sha256=156072000d465b68c1e4c7d40f27af4e724cd63c7efb7ef83fdfdd9dfbb1ece0; output-bytes=65899; shell=/bin/sh; cwd=/Users/nont/my-project/PRC-PhotoBooth; path=8856c3cc55bf/22 entries
