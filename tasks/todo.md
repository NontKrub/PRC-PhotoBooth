# PRC PhotoBooth PR #7 Fix TODO

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

- [ ] Add platform-neutral customer state/actions
- [ ] Add iPad adapter
- [ ] Add Mac external adapter
- [ ] Consolidate phase routing
- [ ] Prevent duplicate button submissions
- [ ] Preserve Thai/English
- [ ] Add workflow tests
- [ ] Run iPad/external parity matrix

## External review

- [ ] Use full-resolution filtered local image
- [ ] Replace fixed 460×360 sizing
- [ ] Use responsive geometry
- [ ] Use `scaledToFit`
- [ ] Add large Keep/Retake controls
- [ ] Add `Photo N of M`
- [ ] Disable controls after decision
- [ ] Test portrait/landscape/square/rotated
- [ ] Test 1080p and 4K/Retina scaling

## Regression

- [ ] QR editor positioning
- [ ] QR final-strip positioning/z-order
- [ ] Local QR scan
- [ ] Cloud QR behavior
- [ ] Physical print scan or mark not run
- [ ] Recovery test
- [ ] Existing download test
- [ ] Mac Debug build
- [ ] Mac Release build
- [ ] iPad Debug build
- [ ] iPad Release build
- [ ] Full test suite
- [ ] Static analysis
- [ ] Address Sanitizer if configured
- [ ] Thread Sanitizer if configured
- [ ] `git diff --check`
- [ ] Review final diff for unrelated files

## GitHub

- [ ] Collect screenshots/recording
- [ ] Summarize automated tests
- [ ] Summarize manual tests
- [ ] Commit logical changes
- [ ] Push `feature/printable-qr-elements`
- [ ] Update PR #7
- [ ] Confirm CI green
- [ ] Do not merge before real ZV-E10 and 3-shot GIF tests pass
