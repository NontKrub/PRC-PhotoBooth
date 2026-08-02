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

# Build + launch both apps (Mac + iPad simulator) in one shot
bash run.sh
```

`project.yml` is the XcodeGen source file. The `.xcodeproj` is generated from it — edit `project.yml`, not the pbxproj.

Swift 6.0, macOS 15.0 / iOS 18.0 deployment targets. `SWIFT_STRICT_CONCURRENCY: targeted`.

## Architecture

Two apps share a `Shared/` layer:

```
Shared/
  Models/SharedTypes.swift        — EventConfig, SharedPhotoSlot, SessionOutput, enums
  Connectivity/Message.swift      — MultipeerConnectivity wire protocol (JSON + raw JPEG)
  Connectivity/MultipeerService.swift
  State/BoothPhase.swift          — session state enum
  State/SessionStateMachine.swift — @Observable state machine

Mac/
  MacApp.swift                    — entry point; injects BoothCoordinator + DataStore into environment
  UI/BoothCoordinator.swift       — @MainActor @Observable hub; owns all services
  UI/OperatorConsoleView.swift    — camera panel, session controls, strip preview
  UI/EventSetupView.swift         — event CRUD, frame PNG import
  UI/FrameSlotEditor.swift        — slot drag/resize/duplicate editor
  UI/AdminDashboardView.swift     — Charts analytics, CSV export (PIN-gated)
  Camera/CameraSource.swift       — protocol for camera backends
  Camera/AVFoundationCameraSource.swift — built-in/USB/Continuity camera
  Camera/DSLRCameraSource.swift   — ImageCaptureCore USB tethered
  Capture/CaptureService.swift    — wraps both cameras; owns capturedStills [Int:CGImage]
  Output/Compositor.swift         — CGBitmapContext strip renderer
  Output/GIFEncoder.swift
  Persistence/BoothModels.swift   — SwiftData @Model classes
  Persistence/DataStore.swift     — ModelContainer init with schema-migration recovery

iPad/
  UI/iPadViewModel.swift          — @Observable; mirrors BoothPhase from Mac messages
  UI/iPadContentView.swift        — routes to phase-specific views
  UI/CountdownView.swift, ReviewView.swift, FinishView.swift, ...
```

## Key Data Flows

**Session lifecycle:** `BoothCoordinator.startSession()` → `SessionStateMachine` drives `BoothPhase` → countdown task fires → `CaptureService.captureStill(for:)` → photo stored in `capturedStills[photoIndex]` → `Compositor.render(images:)` composites strip → saved to `Application Support/PRC-PhotoBooth/Sessions/<id>/strip.png`.

**Mac → iPad messaging:** All control messages are `Message` enum encoded as JSON, prefixed with a `PacketChannel` byte (`0x01` = control, `0x02` = raw JPEG preview). `MultipeerService` sends over MPC reliable channel for control, unreliable for preview frames.

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

`PINGateView` gates the Event Setup and Analytics tabs. The PIN is stored in the macOS Keychain via `KeychainHelper`. Default PIN is `1234` if none is set.
