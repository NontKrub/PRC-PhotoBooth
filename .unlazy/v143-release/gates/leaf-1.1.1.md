# Gates: cloud guest route authority

OWNS: Mac/Output/SessionQRCodePayloadResolver.swift, Mac/Cloud/CloudUploadService.swift, Mac/Jobs/SessionJobExecutor.swift, Tests/SessionQRCodePayloadResolverTests.swift, Tests/CloudUploadServiceTests.swift

Scope: unify normal/soak cloud guest route construction across QR rendering, publication, verification, and cleanup.

- [ ] G1: QR route, upload alias, verification URL, and cleanup alias agree for normal and soak manifests
  CHECK: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/SessionQRCodePayloadResolverTests -only-testing:PRC-PhotoBoothTests/CloudUploadServiceTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'CLOUD_ROUTE_TESTS_PASSED\n'
  EXPECT: CLOUD_ROUTE_TESTS_PASSED
  EVIDENCE: pending

- [ ] G2: cloud QR destination is the route whose non-empty strip is verified by the uploader
  EVIDENCE: pending
