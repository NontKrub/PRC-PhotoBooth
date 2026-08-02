# PRC PhotoBooth

PRC PhotoBooth is a SwiftUI photo-booth system for macOS and iPad. The Mac app runs the booth, controls the camera, stores sessions, renders the finished outputs, and serves guest downloads. The iPad app provides the customer-facing kiosk flow for starting a session, reviewing photos, and retrieving the result.

## Features

- Configurable events with photo count, countdown duration, canvas size, frame PNGs, and editable photo slots.
- Camera support through AVFoundation for built-in, USB, and Continuity Cameras.
- USB-tethered DSLR/mirrorless capture through ImageCaptureCore, including live preview for supported Sony PTP cameras.
- Customer workflow with countdowns, photo review, keep/retake decisions, and operator overrides.
- Live preview over MultipeerConnectivity, with an optional USB-C preview transport for lower-latency wired preview.
- Composited PNG strips, looping animated GIFs, QR-code download links, and optional printing to a connected Selphy printer.
- Local guest download server on port `8585`.
- SwiftData persistence, PIN-gated event setup and analytics, CSV export, and an external-display viewer.

## Architecture

```text
┌─────────────────────┐       MultipeerConnectivity       ┌─────────────────────┐
│  macOS operator app │ ─────────────────────────────────▶ │  iPad kiosk app     │
│                     │   control + wireless preview       │                     │
│ camera / capture    │ ◀──────── optional USB preview ─── │ start / review / QR  │
│ persistence / output│                                     │                     │
└──────────┬──────────┘                                     └─────────────────────┘
           │
           └── Shared models, session state machine, and message protocol
```

Control messages are JSON-encoded and sent reliably. Preview frames are JPEG data sent through a separate high-bandwidth channel. In wired mode, the Mac advertises `_prc-hq._tcp` over Bonjour and the iPad receives preview frames over the USB-C network connection; session controls still use the MultipeerConnectivity channel.

## Requirements

- macOS 15 or later
- iPadOS 18 or later
- Xcode 27 and Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) when regenerating the project from `project.yml`
- A camera supported by AVFoundation or a compatible USB-tethered camera for DSLR mode
- Local-network access between the Mac and iPad for discovery and control

The Mac target is configured as a universal application for Apple Silicon and Intel Macs. Camera, microphone, and local-network permissions must be granted at first launch. A USB-C preview also requires a trusted cable connection between the Mac and iPad.

## Getting started

Clone the repository and open the generated project:

```bash
git clone <repository-url>
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
4. Launch the iPad app on the same local network. The apps discover each other automatically through MultipeerConnectivity.
5. Choose Wireless or Cable for the preview transport if needed. Cable mode is for the live preview stream; it does not replace the control connection.
6. Start a session from the iPad or operator console. After each capture, keep the photo or retake it.
7. When the session finishes, the Mac renders the strip and GIF, shows a QR code for downloads, and offers printing when a printer is configured.

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
└── <event-name>/<yyyyMMdd-HHmm>/
    ├── strip.png
    ├── booth.gif
    └── shot_<index>.jpg
```

The local web server exposes tokenized download pages at `/s/<token>/`. The QR code uses the Mac's LAN address by default, or an optional public base URL configured in Event Setup. Completed sessions older than 60 days are cleaned up when the Mac app starts.

## Project layout

```text
Mac/       macOS operator app: camera, capture, persistence, server, output, and UI
iPad/      iPad customer app and phase-specific SwiftUI screens
Shared/    models, state machine, QR generation, and connectivity protocol
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

No license file is currently included. Add a license before distributing the project or accepting external contributions.
