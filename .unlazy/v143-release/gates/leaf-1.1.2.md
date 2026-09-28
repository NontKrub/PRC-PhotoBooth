# Gates: gallery and history isolation

OWNS: Mac/Gallery/**, Mac/Persistence/BoothModels.swift, Mac/Persistence/DataStore.swift, Mac/UI/AdminDashboardView.swift, Tests/EventGalleryStoreTests.swift, Tests/GalleryRouterTests.swift, Tests/RetakeTrackingTests.swift, Tests/EventExperienceStoreTests.swift

Scope: persist soak provenance and exclude soak sessions from normal gallery routes, history, and statistics while keeping gallery processing active.

- [ ] G1: soak gallery entries persist origin/run metadata and never appear in a normal public gallery
  CHECK: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/EventGalleryStoreTests -only-testing:PRC-PhotoBoothTests/GalleryRouterTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'GALLERY_ISOLATION_TESTS_PASSED\n'
  EXPECT: GALLERY_ISOLATION_TESTS_PASSED
  EVIDENCE: pending

- [ ] G2: legacy SwiftData rows default to normal and soak rows retain run/cycle metadata
  CHECK: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -quiet -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -only-testing:PRC-PhotoBoothTests/RetakeTrackingTests -only-testing:PRC-PhotoBoothTests/EventExperienceStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test && printf 'HISTORY_ISOLATION_TESTS_PASSED\n'
  EXPECT: HISTORY_ISOLATION_TESTS_PASSED
  EVIDENCE: pending

- [ ] G3: normal history and statistics exclude active and completed soak sessions
  EVIDENCE: pending
