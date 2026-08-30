# Current release: v1.4.2 — Stability, Printing, Connectivity & Pairing

This is the active checklist. Historical v1.3/v1.4 notes remain below and are not release instructions.

- [x] Fix printer cancellation outcome and preflight mapping; cancellation is skipped, not passed or failed.
- [x] Remove misleading Actual Size mode and retain native macOS print-panel controls.
- [x] Treat unknown disk space as warning/unknown; make Operations refresh task cancellation-aware.
- [x] Add explicit manual LAN retry, two-second discovery grace, conservative idle recovery, and focused route tests.
- [x] Persist device identity/name; store trusted metadata in preferences and pairing secrets in Keychain.
- [x] Add protocol-v3 pairing/auth messages, six-digit PIN, two-minute expiry, attempt limit, QR payload, HMAC reconnect, forget, and selected-peer policy.
- [x] Add Mac/iPad pairing settings, QR scanner permission/error paths, accessibility identifiers, and localized visible strings.
- [x] Update CI triggers, Release artifacts, generic device compile, stable runner lane, README, and current release plan.
- [x] Run final full Mac and iPad automated matrix; Mac tests 337/337 and iPad tests 4/4 passed; Mac/iPad Debug and Release builds plus generic iOS Release compile passed.
- [x] Run final Ponytail review; removed one unused discovery helper, then reran the final gates.
- [ ] Run Computer Use Mac/iPad GUI matrix; record blocked window/camera/network cases honestly.
- [ ] Run physical Ethernet, PIN/QR, printer, camera, and long-run gates.
- [ ] Mark release-ready only after all non-hardware blockers pass.

---

# Historical: PRC PhotoBooth v1.3 TODO

## Current reliability/network/GIF task

- [x] Record branch, starting SHA, dirty worktree, architecture, and baseline failures
- [ ] Make iPad route selection honor the Mac's advertised network preference
- [ ] Add LAN grace/fallback and stale discovery-generation tests
- [ ] Replace `gifExpected` with explicit none/preparing/ready/failed state
- [ ] Add queue-driven GIF state and terminal-failure guest behavior
- [ ] Add Compact/Balanced/High GIF presets with legacy Balanced decoding
- [ ] Add quality selector and persistence coverage
- [ ] Add production `TemplateGIFRenderer` frame/layer/fallback/failure tests
- [ ] Reduce renderer peak image retention without excessive re-decoding
- [ ] Stream large local media files with bounded chunks and integrity tests
- [ ] Show GIF metadata size and large-file warning on the guest page
- [ ] Validate atomic GIF publication and abandoned temporary-file recovery
- [ ] Refresh foreground-only staged template previews
- [ ] Separate committed event configuration from derived preview rebuild errors
- [ ] Run full tests, all four builds, Computer UI flow, benchmarks, and final integrated regression

### Current task checkpoint

- [ ] Network/GIF state/preset slices focused tests and builds pass
- [ ] Renderer/server/editor slices focused tests and builds pass
- [ ] Final suite/build/UI/benchmark/integrity report complete

## Reliability-hardening completion ledger

- [x] Record startup component health and surface required persistence/server failures in Preflight
- [x] Decouple DSLR still-capture readiness from AVFoundation permission
- [x] Add session identity, Mac-issued sequence numbers, reconnect sync, and stale-message rejection
- [x] Guard normal `SessionStateMachine` events and isolate authoritative restore/sync
- [x] Synchronize Mac/iPad countdowns with absolute capture deadlines
- [x] Add reliability, preflight, message-gate, state-machine, countdown, and occupied-port tests
- [x] Build Mac/iPad Debug and Release configurations; preserve macOS 15/iOS 18 and universal Mac architectures
- [ ] Resolve pre-existing Thai localization test failure
- [ ] Repeat Computer Use UI matrix when app-window access is available
- [ ] Run physical Sony ZV-E10 and real-iPad reconnect matrix

## v1.3 release gate

- [x] Add recoverable capture phase and guest/External Display recovery actions
- [x] Isolate DSLR capture attempts and resolve disconnects immediately
- [x] Persist capture-attempt diagnostics with legacy-compatible decoding
- [x] Add Network.framework transport, framing, heartbeat, reconnect, and state sync
- [x] Add unified health/queue/printer/delivery diagnostics
- [x] Add authenticated LAN operator dashboard and offline sharing station
- [x] Add HTTP, framing, auth, recovery, delivery, station, and manifest tests
- [ ] Run final Mac/iPad builds and final test suite after documentation cleanup
- [ ] Run Computer Control GUI matrix with demo/fault-injection arguments
- [ ] Run Sony ZV-E10 hardware matrix if hardware is available
- [ ] Push branch and create the v1.3 PR after all checks

---

# Historical: PR #7 Fix TODO

## Baseline

- [x] Read `CLAUDE.md` and `tasks/plan.md`
- [x] Fetch latest `feature/printable-qr-elements`
- [x] Record starting SHA: `68d7c92b7cc0a1f949c212051c297585783661de`
- [x] Run XcodeGen
- [x] Run baseline Mac build — PASS
- [x] Run baseline iPad build — PASS
- [x] Run baseline tests — FAIL: pre-existing missing Thai catalog entry in modified `Mac/Localizable.xcstrings`
- [x] Reproduce GIF truncation by tracing global `maxFrames`/stride path; hardware/session capture not run
- [x] Reproduce missing layout background by tracing editor; `TemplateFrameSlotEditor` has no frame input
- [x] Reproduce slow Guest Experience reopen by tracing one full document load per preview
- [x] Reproduce external-display wrong camera by tracing AVFoundation-only external preview; ZV-E10 hardware unavailable
- [x] Record current external review layout — fixed `460 × 360` with `scaledToFill`

## GIF

- [x] Add per-shot frame sampler
- [x] Sample complete source range
- [x] Normalize every shot independently
- [x] Remove global tail truncation
- [x] Use exact GIF destination frame count
- [x] Preserve retake replacement (existing workspace coverage retained)
- [x] Add sampler tests
- [x] Add GIF metadata tests
- [ ] Manually test 3 × 5-second session — hardware/session capture not available here

## Guest Experience editor

- [x] Add safe frame-read API
- [x] Load frame into template editor
- [x] Render frame behind canvas elements
- [x] Refresh frame after replacement
- [x] Handle missing/corrupt frame
- [x] Add frame-store tests
- [ ] Verify compositor/editor alignment — manual UI check pending

## Single layout source

- [x] Remove legacy layout write controls from Event Settings
- [x] Add read-only default-template summary
- [x] Add `Edit Guest Experience…` navigation
- [x] Keep legacy fields for compatibility
- [x] Document one-way legacy mirror
- [x] Test legacy migration/mirroring

## Loading performance

- [x] Remove repeated document decode per preview
- [x] Add bulk/direct preview reads
- [x] Add cancellation checks
- [x] Propagate `CancellationError`
- [x] Cancel stale loads
- [x] Cache previews
- [x] Add dirty-state/Back behavior (`Back` explicitly discards unsaved edits)
- [ ] Rapid open/close test — manual UI check pending

## Active camera preview

- [x] Add shared preview resolver
- [x] Prefer ZV-E10 PTP image
- [x] Allow only non-built-in DSLR fallback session
- [x] Never silently show Mac camera in DSLR mode
- [x] Use resolver in console
- [x] Use resolver in external idle/countdown
- [x] Add resolver tests
- [ ] Test Sony disconnect/reconnect — ZV-E10 hardware not connected here

## Shared customer workflow

- [x] Add platform-neutral customer state/actions
- [x] Add iPad adapter
- [x] Add Mac external adapter
- [x] Consolidate phase routing
- [x] Prevent duplicate button submissions
- [x] Preserve Thai/English
- [x] Add workflow tests
- [ ] Run iPad/external parity matrix — manual UI check pending

## External review

- [x] Use full-resolution filtered local image
- [x] Replace fixed 460×360 sizing
- [x] Use responsive geometry
- [x] Use `scaledToFit`
- [x] Add large Keep/Retake controls
- [x] Add `Photo N of M`
- [x] Disable controls after decision
- [x] Test portrait/landscape/square/rotated (geometry coverage)
- [ ] Test 1080p and 4K/Retina scaling — manual display check pending

## Regression

- [x] QR editor positioning
- [x] QR final-strip positioning/z-order
- [x] Local QR scan
- [x] Cloud QR behavior
- [ ] Physical print scan or mark not run
- [x] Recovery test
- [x] Existing download test
- [x] Mac Debug build
- [x] Mac Release build
- [x] iPad Debug build
- [x] iPad Release build
- [x] Full test suite — 139 tests in 33 suites
- [x] Static analysis — Mac/iPad Debug and Release
- [x] Address Sanitizer if configured — 139 tests passed
- [x] Thread Sanitizer if configured — 139 tests passed
- [x] `git diff --check`
- [x] Review final diff for unrelated files; unrelated worktree changes left untouched

## GitHub

- [ ] Collect screenshots/recording — app window unavailable to Computer Use
- [x] Summarize automated tests
- [x] Summarize manual tests; ZV-E10/display checks remain pending
- [x] Commit logical changes
- [x] Push `feature/printable-qr-elements` — implementation head `6a282dd`
- [x] Update PR #7
- [x] Confirm CI green for final ledger commit `f5daeb1` — PR App Builds run 15 passed
- [x] Do not merge before real ZV-E10 and 3-shot GIF tests pass

## v1.4 implementation checklist

- [ ] Work only on `feature/v1.4-operator-experience-connectivity`; preserve unrelated worktree changes.
- [ ] LAN: initial `.unsatisfied` does not abort a wired attempt; timeout/loss still falls back correctly.
- [ ] LAN: expose route, handshake, control/preview, and bounded preview counters/throughput diagnostics.
- [ ] Review: dedicated larger current-review JPEG; small kept-shot thumbnails remain in snapshots.
- [ ] Review: responsive iPad layout and payload/reconnect tests.
- [ ] Preview: Auto/Standard/High policy with route hysteresis; preserve Sony original JPEG path.
- [ ] Guest Experience: top navigation, 24 pt outer padding, staged Save/Back behavior.
- [ ] Printing: remove app paper/copies/printer/skip-dialog controls; use system print panel for test/manual jobs.
- [ ] Settings: top navigation; Security owns PIN reset and re-locks after reset.
- [ ] Operations: collapsible sections with readiness open and failure badges visible.
- [ ] Event Setup: `Set` selection, range/command selection, safe batch deletion and confirmation.
- [ ] Frame editor: multi-selection, delete/duplicate/group move/nudge, focused shortcuts, undo/redo.
- [ ] Version 1.4 in `project.yml`; regenerate Xcode project.
- [ ] Mac Debug/Release, iPad Debug/Release, and full Swift Testing suite pass.
- [ ] Computer Use Mac UI test attempted; physical iPad/device test attempted and blockers recorded.
- [ ] Delete only recorded temporary test events; restore PIN to `1324`; final diff/security/artifact review.

## v1.4 completion ledger

- [x] Guest Experience staged Save/Back lifecycle
- [x] Operations failure badges remain visible while collapsed
- [x] Event single-active invariant
- [x] Frame editor anchor-aware Undo/Redo
- [x] 24 pt Guest Experience spacing
- [x] LAN regression tests
- [x] Printing regression
- [x] Review image/reconnect regression
- [x] Preview Auto/Standard/High regression
- [x] Mac Debug/Release and iPad Debug/Release final builds
- [x] Full test suite: 286 passed; one documented pre-existing localization failure
- [ ] Computer Use Mac validation: launch passed; UI interaction blocked by native pipe closure
- [ ] Physical hardware validation (not run; hardware unavailable)
