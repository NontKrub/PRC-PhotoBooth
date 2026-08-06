# PRC PhotoBooth — PR #7 Stabilization and External Display Plan

## Context

Execute this work against:

- Repository: `NontKrub/PRC-PhotoBooth`
- Pull request: `#7`
- Branch: `feature/printable-qr-elements`
- Reviewed baseline head: `68d7c92b7cc0a1f949c212051c297585783661de`

Fetch the latest remote branch before changing code. The branch may have moved since this plan was written.

## Objectives

1. Fix the final GIF so every accepted photo contributes the intended duration.
2. Show the imported frame PNG in the Guest Experience layout editor.
3. Remove the duplicate legacy layout editor from Event Settings.
4. Make Guest Experience close/reopen quickly and safely.
5. Make the external display use the same active camera source as the console, including Sony ZV-E10 PTP live view.
6. Make the external-display workflow match the iPad customer workflow.
7. Make the external review photo large, uncropped, and crisp.
8. Add comprehensive automated and manual testing.
9. Push the completed implementation to the PR #7 branch and update the GitHub PR.

## Out of scope

- Independent second-mouse control.
- Raw HID handling, virtual cursors, Input Monitoring, or mouse-device seizure.
- New third-party dependencies.
- Unrelated redesigns of cloud upload, printing, galleries, or QR routing.
- Manual editing of `PRC-PhotoBooth.xcodeproj/project.pbxproj`; edit `project.yml` and regenerate.

---

# Root causes to address

## 1. GIF final segment is too short

The current GIF path combines frames from all accepted shots and applies a session-wide maximum. Integer-division subsampling can produce a stride of `1`, after which encoding stops at the maximum frame count. This preserves the front of the combined array and disproportionately removes the final shot.

Additional problems:

- The destination frame count can be created using the original count even when fewer frames are added.
- A global budget lets one shot consume another shot’s intended duration.
- A fixed delay is applied without explicitly normalizing each shot to a target duration.

## 2. Guest Experience editor does not show the frame

`TemplateFrameSlotEditor` receives slots, QR elements, canvas dimensions, and photo count, but not the frame image or frame URL. Its canvas always renders a white background and grid.

## 3. Layout editing is duplicated

Two separate write paths exist:

- Event Settings edits legacy SwiftData `BoothEvent` / `BoothSlot`.
- Guest Experience edits JSON-backed `EventExperienceDocument` / `EventTemplateDefinition`.

`LegacyEventMirrorService` later mirrors Guest Experience back into the legacy event, so edits made in Event Settings can be overwritten.

## 4. Guest Experience is slow after Cancel/Back

Template preview loading repeats full document loading/validation for each template and is not explicitly cancellation-aware. Closing the screen can leave actor/file work running, causing immediate reopening to wait.

## 5. External display shows the Mac camera in DSLR mode

`ExternalDisplayView.cameraPreview` directly uses the AVFoundation capture session. It does not follow the console logic and does not render `capture.dslr.latestPreviewImage`.

## 6. External workflow drifts from iPad and review is too small

The Mac external display and iPad each implement their own phase routing and controls. The external viewer already has the full local filtered still but displays it in a fixed `460 × 360` frame using `scaledToFill`, making it small and possibly cropped.

---

# Architecture requirements

## Guest Experience is the layout source of truth

The JSON-backed Guest Experience document is authoritative for:

- Templates
- Frame assets
- Canvas dimensions
- Photo count
- Photo slots
- QR elements
- Pose prompts
- Filters
- Language
- Gallery configuration

Legacy event fields may remain as a compatibility mirror but must not expose an independent layout write path.

## One active-preview resolver

Do not copy camera-selection conditions between the console and external display.

Introduce a shared resolver used by both.

Recommended DSLR-mode priority:

1. Demo image in Debug demo mode.
2. Sony PTP `dslr.latestPreviewImage`.
3. Explicitly selected **non-built-in** AVFoundation fallback preview.
4. `dslr.lastCapturedImage` as a clearly frozen fallback.
5. Explicit unavailable/standby screen.

When DSLR is selected, never silently show the built-in Mac camera.

## Shared customer workflow with platform adapters

Create a common customer-display presentation/action interface.

- iPad adapter: `iPadViewModel`, Multipeer messages, transmitted preview/review assets.
- Mac external adapter: `BoothCoordinator`, `SessionStateMachine`, local full-resolution images.

Do not make the Mac external viewer depend directly on `iPadViewModel`, and do not make the iPad depend on `BoothCoordinator`.

---

# Phase 0 — Baseline and reproduction

## Tasks

1. Read:
   - `CLAUDE.md`
   - `tasks/plan.md`
   - `tasks/todo.md`
2. Fetch the latest `feature/printable-qr-elements`.
3. Record the starting SHA.
4. Run `git status --short`; preserve unrelated changes.
5. Generate the project:
   ```bash
   xcodegen generate
   ```
6. Run baseline builds/tests:
   ```bash
   xcodebuild -scheme PRC-PhotoBooth-Mac \
     -destination "platform=macOS" clean build

   xcodebuild -scheme PRC-PhotoBooth-iPad \
     -destination "generic/platform=iOS Simulator" clean build

   xcodebuild -scheme PRC-PhotoBoothTests \
     -destination "platform=macOS" test
   ```
7. Reproduce and document:
   - Three-photo GIF with a shortened final segment.
   - Frame imported but absent from Guest Experience layout editor.
   - Close and immediately reopen Guest Experience repeatedly.
   - ZV-E10 visible in console while external viewer shows Mac camera.
   - External review image visibly too small on 1080p or larger monitor.

## Exit criteria

- Baseline results recorded.
- Each defect reproduced or marked hardware-dependent.
- No implementation starts from an unknown dirty state.

---

# Phase 1 — Fix GIF duration per accepted shot

## Design

Normalize each shot separately before combining shots.

Recommended output:

- Clip duration per accepted shot: `5.0 seconds`
- Output FPS: `12`
- Frames per shot: `60`

The rolling source may deliver more or fewer frames. Evenly sample the complete source range so the first and last frames remain represented.

## Implementation

1. Add a pure/testable sampler, for example:
   ```swift
   struct GIFFrameSampler {
       let targetFramesPerShot: Int
       func sample(_ frames: [CGImage]) -> [CGImage]
   }
   ```
2. Normalize **each shot** independently.
3. Flatten normalized shots in `photoIndex` order.
4. Edge cases:
   - Empty frames: omit that shot’s animation contribution and log a diagnostic; do not fail required strip output.
   - One frame: repeat to the target count.
   - Fewer than target: choose/repeat distributed indexes.
   - More than target: evenly sample the entire range.
5. Refactor `GIFEncoder`:
   - Receive final sampled frames.
   - Use the exact added-frame count when creating the destination.
   - Remove the global tail-truncating limit.
   - Validate non-empty frames and positive delay.
   - Preserve atomic temporary-file replacement.
6. Keep selected filtering applied exactly once.
7. Preserve retake replacement semantics.

## Tests

- 75 source frames → 60, including the final source frame.
- 50 source frames → 60, including the final source frame.
- 1 source frame → 60 repeated frames.
- Three shots → 180 total frames.
- Each shot occupies exactly 60 consecutive frames.
- The last output frame belongs to the final shot.
- GIF metadata reports the expected frame count and delay.
- Retake replaces prior GIF frame files.
- Empty GIF input does not prevent strip completion.

## Manual acceptance

For a three-photo, five-second event:

- All three GIF sections have approximately equal duration.
- The final section is not around two seconds.
- The GIF loops normally.
- Test Original, Monochrome, and one color filter.

---

# Phase 2 — Show the frame in Guest Experience layout editor

## Design

The editor should receive the actual frame asset from `EventExperienceStore`, not construct filesystem paths independently.

## Implementation

1. Add a safe store API:
   ```swift
   func readTemplateFrame(
       eventID: String,
       templateID: String
   ) throws -> Data?
   ```
2. Use the template’s `frameFileName`.
3. Reject invalid names/path separators.
4. Load/decode the frame when template detail opens.
5. Pass immutable frame data or a decoded image to `TemplateFrameSlotEditor`.
6. Render:
   1. White fallback
   2. Frame image fitted exactly to the canvas
   3. Grid
   4. Slots and QR elements in z-order
   5. Selection outlines/handles
7. Refresh immediately after Import/Replace Frame succeeds.
8. Show a non-blocking error for missing/corrupt frame.
9. Ensure editor coordinates align with final compositor coordinates.

## Tests

- Valid frame can be read.
- Missing frame is handled.
- Invalid filename/path is rejected.
- Replacing a frame changes returned data.
- Coordinate conversion is unchanged with a background.

## Manual acceptance

- The imported PNG is visible behind slots and QR.
- Slots align with visible frame artwork.
- Replacing the frame is reflected after reopen.
- No-frame templates still show a usable white canvas/grid.

---

# Phase 3 — Remove duplicate legacy layout editing

## Design

Event Settings manages event-level settings. Guest Experience is the only layout editor.

## Implementation

1. Remove/disable Event Settings controls for:
   - Frame import
   - Canvas dimensions
   - Photo-slot editing
   - Legacy editor sheet
2. Replace with a read-only default-template summary:
   - Template name
   - Photo count
   - Canvas size
   - Photo-slot count
   - QR-element count
3. Add one clear navigation action:
   `Edit Guest Experience…`
4. Keep event-level controls:
   - Event name
   - Active state
   - Countdown
   - Camera rotation/configuration
   - Remote/cloud configuration where currently appropriate
5. Keep legacy persistence fields for compatibility.
6. Document `LegacyEventMirrorService` as a one-way mirror from Guest Experience.
7. Remove dead legacy editor state/imports from Event Settings.
8. Do not delete legacy schema fields in this PR.

## Tests

- Saving Guest Experience mirrors the default template.
- Changing default template updates the legacy mirror.
- Frame path, dimensions, photo count, and slots mirror correctly.
- Old legacy events still migrate to a first experience document.

## Manual acceptance

- Only one visible layout-editing route remains.
- Event Settings directs users to Guest Experience.
- Guest Experience changes survive close/reopen and relaunch.

---

# Phase 4 — Make Guest Experience loading cancellable and fast

## Design

Load the document once and avoid decoding/validating it again for every preview.

## Implementation

1. Use the already-loaded document/template list for preview reads.
2. Add a bulk/direct preview API, for example:
   ```swift
   func readTemplatePreviews(
       eventID: String,
       templates: [EventTemplateDefinition]
   ) throws -> [String: Data]
   ```
3. Add `Task.checkCancellation()` before/after filesystem work.
4. Propagate `CancellationError`; do not display it as a user error.
5. Cancel old loads on disappear or replacement.
6. Cache decoded previews for the editor lifetime.
7. Invalidate only the template whose frame/layout changed.
8. Separate save state from preview-loading state.
9. Clarify Back/Cancel behavior:
   - If dismissing discards unsaved edits, track dirty state and confirm.
   - Otherwise label it `Back`.

## Tests

- Preview loading does not decode the full document once per template.
- Cancellation does not set an error.
- One missing preview does not block other previews.
- Rebuilding one preview invalidates only that template.

## Manual acceptance

- Open/close Guest Experience ten times rapidly.
- Immediate reopen does not stall.
- Replaced frames/previews update.
- Unsaved-change behavior is clear and consistent.

---

# Phase 5 — Shared active camera preview

## Suggested contract

```swift
enum ActiveCameraPreview {
    case still(CGImage)
    case session(AVCaptureSession, mirrored: Bool)
    case unavailable(title: String, detail: String)
}
```

If actor/Sendable rules make this unsuitable, expose an `@MainActor` presentation model with equivalent cases.

## Implementation

1. Extract console preview selection into a shared resolver.
2. DSLR mode:
   - Prefer `dslr.latestPreviewImage`.
   - Permit AVFoundation fallback only when selected device is non-built-in.
   - Optionally use `dslr.lastCapturedImage` as a frozen fallback.
   - Otherwise show unavailable.
3. AVFoundation mode:
   - Use selected AVFoundation session.
4. Use resolver in:
   - Operator console
   - External idle view
   - External countdown view
5. Preserve AVFoundation mirror behavior.
6. Do not mirror Sony PTP images unless explicitly required.
7. Add Debug/operator source badge for validation.

## Tests

- Demo mode → demo image.
- DSLR + Sony PTP image → Sony image.
- DSLR + non-built-in AVF fallback → fallback session.
- DSLR + only built-in Mac camera → unavailable.
- DSLR + last captured image → frozen fallback according to final policy.
- AVFoundation selected → AVF session.
- No source → unavailable.

## Manual Sony acceptance

- Console and external viewer show the same ZV-E10 scene.
- Covering the Mac camera does not alter external preview.
- Countdown uses Sony preview.
- Disconnecting Sony never silently shows Mac camera.
- Reconnection recovers where existing camera service supports it.

---

# Phase 6 — Align external display with iPad workflow

## Required shared workflow

- Idle/start
- Experience selection
- Ready/start confirmation
- Countdown and pose prompt
- Processing
- Review with Keep/Retake
- Finish/QR
- Next session/reset
- Selected language/localization

## Implementation

1. Add platform-neutral customer-display state/action interfaces under `Shared/`.
2. Add iPad adapter backed by `iPadViewModel`.
3. Add Mac external adapter backed by `BoothCoordinator`/`SessionStateMachine`.
4. Consolidate phase routing and label/action rules.
5. Keep transport platform-specific.
6. Ensure identical semantic actions:
   - Start
   - Confirm experience
   - Keep
   - Retake
   - Next session
7. Prevent duplicate submissions by disabling controls until phase changes.
8. Preserve operator overrides.
9. Add missing English/Thai localization.

## Tests

- Same phase maps to same screen type on both adapters.
- Keep/Retake uses correct photo index.
- Selection-required start enters selection.
- No-selection start begins session.
- Finished/next resets correctly.
- Duplicate button submissions are ignored.

## Manual parity flow

Run on iPad and external display:

1. Idle
2. Select template/filter/language
3. Ready
4. Countdown with prompt
5. Review → Retake
6. Review → Keep
7. Complete remaining photos
8. Processing
9. Finished QR
10. Next session

Confirm equal phase order and decisions.

---

# Phase 7 — Large, crisp external review

## Design

Use the local full-resolution filtered image:

```swift
coordinator.currentFilteredReviewImages[photoIndex]
    ?? coordinator.capture.capturedStills[photoIndex]
```

Do not create or display a 200-pixel thumbnail on the external screen.

## Implementation

1. Use responsive geometry.
2. Display photo with `.scaledToFit()`.
3. Suggested bounds:
   - Max width: 75–82% of display width
   - Max height: 62–72% of display height
4. Preserve complete aspect ratio.
5. Use high-quality interpolation.
6. Support landscape, portrait, square, and rotated images.
7. Large kiosk controls:
   - Minimum height about 64 px at 1080p
   - Clear Keep primary / Retake secondary hierarchy
   - Visible hover/focus states
8. Show `Photo N of M`.
9. Disable both actions after one click until state changes.
10. Keep the window borderless/full-screen on the chosen display.

## Tests

Keep sizing rules in a pure helper and test:

- Aspect ratio preserved.
- Image does not exceed its region.
- Portrait and landscape use space appropriately.
- Controls remain in bounds at 1920×1080 and 3840×2160.

## Manual visual acceptance

- 1920×1080 display.
- 4K/Retina-scaled display if available.
- Landscape Sony still.
- Portrait/rotated still.
- Synthetic square and wide images.

The full image must be visible, significantly larger than 460×360, and clear enough to inspect face/clothing detail.
