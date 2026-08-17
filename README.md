# PRC PhotoBooth

PRC PhotoBooth is a SwiftUI photo-booth system for macOS and iPad. The Mac app runs the booth, controls the camera, stores sessions, renders the finished outputs, and serves guest downloads. The iPad app provides the customer-facing kiosk flow for starting a session, reviewing photos, and retrieving the result.

## Features

- Configurable events with photo count, countdown duration, canvas size, frame PNGs, and editable photo slots.
- Camera support through AVFoundation for built-in, USB, and Continuity Cameras.
- USB-tethered DSLR/mirrorless capture through ImageCaptureCore, including live preview for supported Sony PTP cameras.
- Customer workflow with countdowns, photo review, keep/retake decisions, and operator overrides.
- Network.framework Mac↔iPad control and preview transport with Bonjour discovery, framing, heartbeat, reconnect, and state resynchronization. MultipeerConnectivity remains a debug fallback.
- Recoverable capture failures with Try Receive Again, Retake, Continue Session, and Keep Previous Photo actions.
- Composited PNG strips, looping animated GIFs, QR-code download links, and optional printing to a connected Selphy printer.
- Local guest download server on port `8585`.
- Booth preflight checks, a non-PIN-gated Operations tab, and persistent processing/upload/print jobs.
- Restart-safe capture recovery and persistent QR registration using absolute session folders.
- SwiftData persistence, PIN-gated event setup and analytics, CSV export, and an external-display viewer.
- Version 1.2 guest experience packages with up to eight templates, local Core Image filters, pose prompts, and Thai/English customer choices.
- Privacy-controlled local event galleries with pending, approved, and hidden moderation states.
- Camera/booth health diagnostics, persistent operations events, delivery-state visibility, reliability analytics, an authenticated LAN operator dashboard, and an offline sharing station.
- Debug-only hardware-free demo camera and standalone iPad kiosk flows.

Version 1.2 has no audio countdown. Countdown and pose prompts are visual only.

## Architecture

```text
┌─────────────────────┐       Network.framework            ┌─────────────────────┐
│  macOS operator app │ ─────────────────────────────────▶ │  iPad kiosk app     │
│                     │   control + preview                │                     │
│ camera / capture    │ ◀────── Wi-Fi or wired LAN ─────── │ start / review / QR │
│ persistence / output│                                    │                     │
└──────────┬──────────┘                                    └─────────────────────┘
           │
           └── Shared models, session state machine, and message protocol
```

Control messages are JSON-encoded and sent reliably over a framed Network.framework control connection. Preview JPEGs use a separate latest-frame-wins connection within the same `NetworkBoothTransport`, so preview traffic cannot delay session controls. The operator chooses Wi-Fi or LAN; LAN requires Network.framework's `.wiredEthernet` interface and falls back to Wi-Fi after a failed path or validated handshake. Bonjour advertises `_prc-control._tcp` and `_prc-preview._tcp`. A DEBUG-only `--legacy-multipeer` flag keeps the old adapter available while hardware migration is validated.

## Requirements

- macOS 15 or later
- iPadOS 18 or later
- Xcode 27 and Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) when regenerating the project from `project.yml`
- A camera supported by AVFoundation or a compatible USB-tethered camera for DSLR mode
- Local-network access between the Mac and iPad for discovery and control

The Mac target is configured as a universal application for Apple Silicon and Intel Macs. Camera, microphone, and local-network permissions must be granted at first launch. LAN mode requires a reachable wired Ethernet path on both devices; otherwise the transport reports and uses Wi-Fi fallback.

## Getting started

Clone the repository and open the generated project:

```bash
git clone [<repository-url>](https://github.com/NontKrub/PRC-PhotoBooth)
cd PRC-PhotoBooth

# Needed after changing project.yml, or if the generated project is absent.
xcodegen generate
open PRC-PhotoBooth.xcodeproj
```

Configure an Apple development team and signing settings in Xcode if automatic signing is not already available on the machine.

### Build the Mac app

```bash
xcodebuild \
  -project PRC-PhotoBooth.xcodeproj \
  -scheme PRC-PhotoBooth-Mac \
  -destination "platform=macOS" \
  build
```

### Build the iPad app

Replace `<simulator-uuid>` with an available iPad simulator identifier, or use a connected iPad destination.

```bash
xcodebuild \
  -project PRC-PhotoBooth.xcodeproj \
  -scheme PRC-PhotoBooth-iPad \
  -destination "platform=iOS Simulator,id=<simulator-uuid>" \
  build
```

### Run tests

The Swift Testing unit-test bundle runs on macOS:

```bash
xcodebuild \
  -project PRC-PhotoBooth.xcodeproj \
  -scheme PRC-PhotoBoothTests \
  -destination "platform=macOS" \
  test
```

`run.sh` can build and launch both apps with a configured iPad simulator. It contains developer-machine-specific project and DerivedData paths, so review or update those paths before using it from another checkout.

## Booth setup

1. Launch the Mac app and grant camera, microphone, and local-network permissions.
2. In Event Setup, create an event, choose the number of photos and countdown, import an optional frame PNG, and set the photo slots.
3. Mark the event as active and select the camera source in the operator console.
4. Launch the iPad app on the same local network. The apps discover each other automatically through Network.framework Bonjour.
5. Choose Wi-Fi or LAN in the Mac operator settings. LAN prefers wired Ethernet and automatically falls back to Wi-Fi if the wired route or validated iPad handshake is unavailable.
6. Start a session from the iPad or operator console. After each capture, keep the photo or retake it.
7. Open Operations before an event and run Safe Checks. Run Full Preflight when a diagnostic camera capture or printer test is appropriate.
8. When the session finishes, queued required jobs make the strip and QR available first; GIF, cloud upload, and automatic printing continue independently.

### Version 1.1 operations

- Accepted photographs are written immediately. A session interrupted during capture appears in Operations with Resume or Discard; no countdown starts automatically.
- A photograph captured but not accepted before the application closed cannot be recovered and must be retaken.
- Runtime manifests and `jobs.json` live under:

  ```text
  ~/Library/Application Support/PRC-PhotoBooth/Runtime/
  ├── Sessions/<session-id>.json
  └── jobs.json
  ```

- Each session creates its output directory at capture start. `.work/` contains frame snapshots and GIF source frames and is removed only after rendering reaches a terminal state.
- QR mappings are restored from completed/finalizing manifests, so old QR links continue to work after restart or an output-folder change while the original absolute folder still exists.
- Cloud uploads and automatic prints retry from the Operations queue. A cloud failure never blocks the local QR download. Automatic printing requires a configured printer and Skip system print dialog.
- Printer diagnostics submit a test page only when the operator requests one. Version 1.1 does not report ink, ribbon, paper, jam, or power levels.

### Version 1.2 guest experience

Event Setup stores guest-facing configuration as atomic JSON packages, so existing SwiftData history remains compatible:

```text
~/Library/Application Support/PRC-PhotoBooth/
├── EventExperiences/<event-id>/
├── Gallery/Events/<event-id>.json
└── Runtime/Sessions/<session-id>.json
```

Operators can create, duplicate, order, enable, disable, and choose a default template. Each template has its own canvas, slots, frame, photo count, preview, and optional Thai/English pose prompts. The kiosk can require template, filter, and language choices; the Mac validates the selection against the current experience revision before creating a session.

Filters are applied to review-sized copies and final strip/GIF renders. Accepted `shot_<index>.jpg` files remain the original photographs and are the recovery source.

The event gallery is local-network only. Disabled galleries publish nothing; approval-required galleries keep new sessions pending until an operator approves them; automatic galleries publish approved thumbnails immediately. Hidden sessions disappear from the gallery but keep their individual download URLs. Regenerating a gallery token invalidates only the old gallery URL, not individual session links.

Debug builds support hardware-free checks:

```text
Mac:  --demo-mode --reset-demo-data --demo-capture-fail-once=1
iPad: --demo-kiosk
```

### Version 1.3 reliability and operations

- A transfer/decode/PTP failure enters Capture Recovery instead of trapping the guest in a dead phase. Recovery can receive the already-fired shutter again, retake, defer the missing index, or restore the accepted image from a transactional retake.
- Capture attempts have IDs and centrally cancelled timeout/poll/download tasks. Camera removal or a closed ImageCaptureCore session immediately resolves the active capture.
- `Camera Health` and `Device Health` show connection, PTP, preview FPS, receive time, capture failures, recovered transfers, queue, disk, printer, and local-server status. Printer values are application-observed job metrics only.
- The Mac serves an authenticated, one-time-paired operator dashboard at `/operator/` and an offline sharing station at `/e/<event-token>/station`. Gallery-disabled, pending, and hidden sessions are not exposed by the station.
- Operational events are bounded to 30 days/10,000 records and contain session/phase metadata only; they do not store guest names or photo contents.
- Deterministic DEBUG fault injection supports `--demo-capture-transfer-timeout=1`, `--demo-camera-disconnect-on=1`, and `--demo-capture-decode-failure=1`. Values are zero-based photo indexes.

Use the computer-based GUI workflow after automated tests to inspect Event Setup, selection, prompts, review, moderation, Thai text, and restart persistence.

### Manual booth-start checklist

1. Confirm the active event has valid slots and the intended frame.
2. Confirm the selected camera is connected and the customer iPad or external viewer is ready.
3. Run Safe Checks; run Full Preflight when physical tests are needed.
4. Confirm output storage, local server health, queue health, printer setup, and cloud status in Operations.
5. Resolve any recoverable capture session before starting a new one.

## Output and storage

Event frame assets are stored under:

```text
~/Library/Application Support/PRC-PhotoBooth/
└── Frames/
    └── <frame>.png
```

The SwiftData store is managed by macOS in the app's application-support storage.

Finished session files are stored under:

```text
~/Pictures/PRC-PhotoBooth/
└── <safe-event-name>/<yyyyMMdd-HHmmss>-<session-id-prefix>/
    ├── .work/
    ├── strip.png
    ├── booth.gif
    └── shot_<index>.jpg
```

The local web server exposes tokenized download pages at `/s/<token>` and `/s/<token>/`, plus `/health`. Only `strip.png` and an existing `booth.gif` are served. The QR code uses the Mac's LAN address by default, or an optional public base URL configured in Event Setup. Completed sessions older than 60 days are cleaned up when the Mac app starts; cancelled manifests are retained for seven days.

The operator dashboard is LAN-only by deployment intent. Pairing tokens are random, one-use, expire after ten minutes, and are invalidated on app restart; paired operator session tokens are separate temporary credentials. The admin PIN is never placed in a URL.

## Project layout

```text
Mac/       macOS operator app: camera, capture, persistence, server, output, diagnostics, and UI
iPad/      iPad customer app and phase-specific SwiftUI screens
Shared/    models, state machine, QR generation, and Network.framework/legacy connectivity adapters
Tests/     Swift Testing unit tests hosted by the Mac target
project.yml
           XcodeGen source of truth for targets, dependencies, and build settings
run.sh     local build-and-launch helper for Mac plus an iPad simulator
```

## Security notes

- The admin PIN is stored in the macOS Keychain. Set a deployment-specific PIN before using the booth in production.
- The local download server is intended for guest access on a trusted network. Treat the QR token and the server port as access credentials, and do not expose port `8585` directly to the public internet without an appropriate proxy and access controls.
- Cloud backup/publishing is optional and depends on the operator's own SSH, `rsync`, and Cloudflare tooling configuration. No server credentials belong in this repository.
- Do not commit signing teams, simulator identifiers, DerivedData paths, private keys, or other machine-specific secrets.

## License

PRC PhotoBooth is licensed under the [Apache License 2.0](LICENSE).

Copyright 2026 Thanawat Suesuthikul.

Bundled logos, app icons, photographs, and third-party materials may be subject to separate rights.
