# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build Mac app only
xcodebuild -scheme PRC-PhotoBooth-Mac -destination "platform=macOS" build

# Build iPad app for simulator
xcodebuild -scheme PRC-PhotoBooth-iPad \
  -destination "platform=iOS Simulator,id=<simulator-uuid>" build

# Run unit tests (Mac host)
xcodebuild -scheme PRC-PhotoBoothTests -destination "platform=macOS" test

# Run unit tests (iPad simulator)
xcodebuild -scheme PRC-PhotoBooth-iPadTests -destination "platform=iOS Simulator,id=<simulator-uuid>" test

# Build + launch both apps (Mac + iPad simulator) in one shot
bash run.sh
```

`project.yml` is the XcodeGen source file. The `.xcodeproj` is generated from it — edit `project.yml`, not the pbxproj.

Swift 6.0, macOS 15.0 / iPadOS 16.0 deployment targets. `SWIFT_STRICT_CONCURRENCY: targeted`.

Xcode 27 uses Device Hub for simulated and physical iPad devices. The command-line
destination string for a simulator remains `platform=iOS Simulator`; there is no
`platform=Device Hub` xcodebuild destination.

## Architecture

Two apps share a `Shared/` layer:

```
Shared/
  Models/           — SharedTypes, ExperienceTypes, LocalizedText
  Connectivity/     — NetworkBoothTransport, Message (JSON wire protocol), BoothPairing (secure auth)
  Imaging/          — BoothImageDecoder, PhotoFilter, QRCodeGenerator, PreviewQuality
  State/            — BoothPhase, SessionStateMachine, CustomerDisplayWorkflow

Mac/
  MacApp.swift      — entry point; injects BoothCoordinator + DataStore into environment
  UI/               — BoothCoordinator, OperatorConsoleView, EventSetupView, AdminDashboardView
  Camera/           — CameraSource protocol, AVFoundationCameraSource, DSLRCameraSource
  Capture/          — CaptureService, RollingVideoBuffer
  Experience/       — CustomerExperienceCatalogBuilder, EventExperienceStore
  Gallery/          — EventGalleryStore, GalleryThumbnailGenerator
  Jobs/             — SessionJobQueue, SessionJobExecutor
  Output/           — Compositor (CGBitmapContext), GIFEncoder
  Persistence/      — DataStore, BoothModels (SwiftData)
  Printing/         — PrinterService
  Runtime/          — SessionWorkspace, SessionManifestStore, SessionRecoveryService
  Server/           — LocalWebServer, LocalDownloadRouter, RemoteOperatorAuth
  SoakTest/         — BoothSoakTestRunner
  Diagnostics/      — BoothHealthSnapshot, BoothPreflightService
  Cloud/            — CloudUploadService

iPad/
  iPadApp.swift     — entry point
  UI/               — iPadViewModel, iPadContentView, ExperienceSelectionView, CountdownView
  Debug/            — DemoKioskDriver
```

## Key Data Flows

**Session lifecycle:** `BoothCoordinator.startSession()` → `SessionStateMachine` drives `BoothPhase` → countdown task fires → `CaptureService.captureStill(for:)` → photo stored in `capturedStills[photoIndex]` → `Compositor.render(images:)` composites strip → saved to `Application Support/PRC-PhotoBooth/Sessions/<id>/strip.png`.

**Mac → iPad messaging:** Control messages are `Message` enum encoded as JSON inside an explicit 8-byte framed Network.framework control stream. Preview JPEGs use a separate latest-frame-wins stream. `NetworkBoothTransport` is the production transport selected by both apps; the legacy `MultipeerService` source is not app-selected.

**Capture recovery:** `BoothPhase.captureRecovery` is authoritative for failed receive/decode/PTP attempts. Actions pass through `CustomerDisplayWorkflow.canApply`; `CaptureService`/`DSLRCameraSource` isolate attempt IDs and cancel all terminal tasks. `SessionSyncSnapshot` rebuilds the iPad after reconnect.

**Operations:** `BoothHealthSnapshot` powers both the Mac Operations UI and authenticated `/operator/api/status`. `LocalWebServer` also serves `/e/<event-token>/station`; `EventGalleryStore` remains the only moderation source.

**Photo index / slot duplication:** `BoothSlot.photoIndex` (and `SharedPhotoSlot.photoIndex`) maps a slot to a capture index. Multiple slots with the same `photoIndex` show the same photo — this is how "duplicate" works. `EventConfig.photoCount` is the number of captures; slot count is independent.

## SwiftData Schema Migration

`DataStore.init()` catches `ModelContainer` init failures, deletes the three SQLite files (`.store`, `.store-shm`, `.store-wal`) and retries. This is intentional: adding non-optional properties to `@Model` types without a migration plan would otherwise crash on launch. Reset is safe for a local-only store.

## CGBitmapContext / Image Orientation

**Compositor** (`Compositor.swift`): The context has a global Y-flip applied (`translateBy(0,h); scaleBy(1,-1)`) so that `ctx.draw(image, in:)` renders images right-side up and the frame PNG (a standard top-left-origin PNG) displays correctly. Slot `destRect.y` is `rect.minY * h` (direct mapping, not `1 - maxY`) because the flip already inverts the axis.

**Camera stills** (`AVFoundationCameraSource.swift`): `CGImageSourceCreateImageAtIndex` strips EXIF orientation. After decoding the capture JPEG, the EXIF orientation tag is read and applied via `CIImage.oriented(_:)` before the CGImage is stored. Without this, camera photos appear rotated in the compositor output.

**Preview display** (`OperatorConsoleView.stripPreviewPanel`): Uses `NSBitmapImageRep(cgImage:)` + `NSImage(size:).addRepresentation(_:)` instead of `NSImage(cgImage:size:)`. The latter applies an extra coordinate flip; `NSBitmapImageRep` preserves raw pixel layout.

## SourceKit False Positives

SourceKit reports "Cannot find type X in scope" errors throughout the Mac target because it cannot resolve cross-file types (`BoothEvent`, `DataStore`, `CameraSource`, etc.) without a full build. These are not real errors — `xcodebuild` compiles succeed. Ignore SourceKit diagnostics; verify with `xcodebuild` instead.

## File Storage Layout

```
~/Library/Application Support/PRC-PhotoBooth/
  <framePNGPath>              — event frame PNG (path stored relative to this dir)
  Sessions/
    <sessionID>/
      strip.png
      booth.gif
      shot_0.jpg, shot_1.jpg, ...
```

Sessions older than 60 days are auto-cleaned on launch. The local HTTP server (`LocalWebServer`, port 8585) serves the Sessions directory under `/s/<downloadToken>`.

## PIN Gate

`PINGateView` gates the Event Setup and Analytics tabs. The PIN is stored in the macOS Keychain via `KeychainHelper`, with bounded retry backoff; a legacy UserDefaults hash is migrated after a successful verification.
