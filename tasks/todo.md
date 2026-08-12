# PRC PhotoBooth v1.3 TODO

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
