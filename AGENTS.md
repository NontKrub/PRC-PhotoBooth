# Repository Guidelines

## Project Structure & Module Organization

PRC-PhotoBooth is a Swift 6 Xcode project generated from `project.yml`. Edit `project.yml` for target, signing, dependency, and build setting changes; avoid hand-editing `PRC-PhotoBooth.xcodeproj/project.pbxproj`.

- `Mac/`: macOS operator app, including camera capture, SwiftData persistence, local web server, output rendering, and operator UI.
- `iPad/`: iPad customer-facing app and phase-specific SwiftUI screens.
- `Shared/`: code shared by both apps, including models, MultipeerConnectivity messaging, and booth state.
- `Tests/`: Swift Testing unit tests hosted by the Mac target.
- `run.sh`: builds and launches the Mac app plus a configured iPad simulator.

## Build, Test, and Development Commands

```bash
xcodegen generate
xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-Mac -destination "platform=macOS" build
xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBooth-iPad -destination "platform=iOS Simulator,id=<simulator-uuid>" build
xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination "platform=macOS" test
bash run.sh
```

Use `xcodegen generate` after changing `project.yml`. Use the Mac and iPad build commands to validate each app separately. Run the test command before submitting behavior changes. `bash run.sh` is useful for manual end-to-end checks, but it contains a machine-specific simulator UUID and DerivedData path.

## Coding Style & Naming Conventions

Use Swift 6 with 4-space indentation, matching `project.yml`. Prefer SwiftUI and `@Observable` patterns already used in `Mac/UI/BoothCoordinator.swift` and `iPad/UI/iPadViewModel.swift`. Keep platform-specific code in `Mac/` or `iPad/`; place wire formats, shared models, and state-machine logic in `Shared/`. Name tests after the behavior under test, for example `MessageTests` and `StateMachineTests`.

## Testing Guidelines

Tests use the Swift Testing framework (`import Testing`) and `#expect`. Add focused tests in `Tests/` when changing `Shared/` behavior, message encoding, compositing logic, or session transitions. Prefer deterministic tests that avoid camera, simulator, network, or filesystem dependencies unless explicitly testing integration behavior.

## Commit & Pull Request Guidelines

Git history is not available in this checkout, so no repository-specific commit convention can be inferred. Use short, imperative commit subjects such as `Fix countdown retake state`. Pull requests should include a concise change summary, test results from `xcodebuild ... test`, linked issues when applicable, and screenshots or recordings for visible Mac/iPad UI changes.

## Security & Configuration Tips

Do not commit local signing teams, personal simulator UUIDs, DerivedData paths, or secrets. The admin PIN is stored in Keychain at runtime; keep default or test PIN changes out of shared configuration unless they are intentional product changes.
