# PRC PhotoBooth v1.4.3 release hardening

Contract revision: 2
Starting SHA: 8cb1249a590632591ac7a759762fecdf5f4f26b1
Branch: fix/v1.4.3-release-hardening
Toolchain: Xcode 27.0 (27A266a), Swift 6.4; repository targets Swift 6.0.

## Contract inventory

| ID | Required outcome | Owner | Observation | Disposition |
|---|---|---|---|---|
| C1 | Normal and soak QR, upload alias, verification URL, and cleanup alias share one route/layout authority; soak QR is the route actually verified. | leaf-1.1.1 + root integration | leaf G1, root G2 | Active |
| C2 | Soak sessions never enter normal local routes or customer gallery; gallery job still persists diagnostic entry. | leaf-1.1.2 + root integration | leaf G1, root G2 | Active |
| C3 | SwiftData stores origin/run/cycle; missing legacy origin is normal; user-facing history/statistics excludes soak. | leaf-1.1.2 + root integration | leaf G2, root G3 | Active |
| C4 | One bounded identity-probe lane authenticates trusted peers despite anonymous slot occupancy, DHCP changes, restart, and spoof attempts. | leaf-1.2.1 | leaf G1 | Active |
| C5 | Production Hello, HMAC, secure-channel bootstrap, heartbeat, browser route discovery, and reconnect progress do not need MainActor. | leaf-1.2.1 | leaf G2 | Active |
| C6 | Cleanup uses one idempotent path, hides exposure before deletion, retains retry diagnostics, and reports remote warnings. | root | root G4 | Active |
| C7 | Resolve interface conflicts only when they affect the chosen route; preserve conservative behavior. | root | root G5 | Active, conditional |
| C8 | Event Readiness shows isolation, route pattern, live subsystem coverage, operational stages, and truthful result states. | root | root G6 + visual review | Active |
| C9 | Preserve A01, A02, A05-A08, legacy side-effect, and print-unknown regressions. | root | root G7 | Active |
| C10 | Run Xcode 27 Mac/iPad Debug, Release, tests, generic iPad Release, package, and stable macOS gates. | root | root G8 | Active |
| C11 | GitHub Actions Xcode 27 and stable macOS lanes pass at final source SHA. | root | root G9 | Active |
| C12 | 500+ production sessions and 4-6 hour hardware/network/camera/print/persistence matrix pass. | operator | root G10 manual | Physical verification pending |
| C13 | Final report uses required matrix and separates software evidence from physical verification. | root | root G11 manual | Active |

## Shared interfaces and conventions

- `CloudGuestRoute` is the single relative guest route authority. Normal routes remain `/s/<downloadToken>/`; soak routes are `/s/soak/<runID>/<sessionID>/`.
- `CloudSessionLayout` is built from a manifest and its saved cloud configuration. Upload, verification, and cleanup consume that layout.
- Missing persisted origin remains `.normal`; unknown future origin values fail closed for customer publication and statistics.
- Only a successful stored-secret HMAC promotes a claimed peer. IP, Bonjour name, and claimed ID remain hints.
- `BoothNetworkTransportRuntime` and `NetworkBoothTransport` must not become competing authorities for the same socket. MainActor receives immutable status/events after transport progress.
- Existing local changes in `Mac/Localizable.xcstrings`, `PRC-PhotoBooth.xcodeproj/project.pbxproj`, and `UserInterfaceState.xcuserstate` are user-owned and excluded from leaf ownership.
- Do not generate or hand-edit the project file unless a project.yml change requires it; preserve the local signing-team edit.

## Tree and leaf dispatch

- 1 Release-hardening root ........ `.unlazy/v143-release/GATES.md`
  - 1.1 Data and guest isolation ... `gates/node-1.1.md`
    - 1.1.1 Cloud route authority ... `gates/leaf-1.1.1.md`
    - 1.1.2 Gallery and history ..... `gates/leaf-1.1.2.md`
  - 1.2 Transport liveness .......... `gates/node-1.2.md`
    - 1.2.1 A03/A04 transport core ... `gates/leaf-1.2.1.md`

| Leaf | Owns | Needs | Tier | Planned wave | State |
|---|---|---|---|---:|---|
| 1.1.1 | Mac/Output/SessionQRCodePayloadResolver.swift, Mac/Cloud/CloudUploadService.swift, Mac/Jobs/SessionJobExecutor.swift, Tests/SessionQRCodePayloadResolverTests.swift, Tests/CloudUploadServiceTests.swift | - | judgment | 1 | READY |
| 1.1.2 | Mac/Gallery/**, Mac/Persistence/BoothModels.swift, Mac/Persistence/DataStore.swift, Mac/UI/AdminDashboardView.swift, Tests/EventGalleryStoreTests.swift, Tests/GalleryRouterTests.swift, Tests/RetakeTrackingTests.swift, Tests/EventExperienceStoreTests.swift | - | judgment | 1 | READY |
| 1.2.1 | Shared/Connectivity/**, Tests/NetworkRouteTests.swift, Tests/BoothPreAuthPolicyTests.swift, Tests/BoothPairingTests.swift | - | judgment | 2 | READY |

Root integration owns `Mac/UI/BoothCoordinator.swift`, `Mac/Runtime/SessionManifest.swift`, `Mac/Server/**`, `Mac/SoakTest/**`, `Mac/UI/SoakTestSettingsView.swift`, `Mac/UI/OperationsView.swift`, `Tests/SoakTests.swift`, `Tests/SessionManifestStoreTests.swift`, and `GATES.md`. No leaf may modify root-owned paths or user-owned files.

## Verification and review

Use Xcode 27 with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Run focused leaf checks, then cross-component regressions, the full local build/test matrix, CI at the final SHA, and independent architecture/security and over-engineering reviews. Read-only audit agents were started before this ledger was written; no agent had write ownership or modified files. Initial transport implementation dispatch returned a design handoff without edits because its ownership was too narrow. Contract revision 2 expands that leaf to the complete connectivity module so one core can own the full control path. Future implementation dispatch must use claims and a sealed native launch wave.

Physical hardware, event-network, 500-session, and 4-6 hour gates require operator evidence and remain unmet until performed on the named equipment.
