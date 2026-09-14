# PRC PhotoBooth — v1.4.2 Stability, Printing, Connectivity & Pairing

## Final event-readiness implementation evidence — 2026-09-14

This section records the completed working-tree pass from reviewed SHA
`42612c82c432899ef723d2bb400e53e2f28dd6b3`. No commit, push, or project-file
regeneration was performed; source membership did not change.

Implemented software slices:

- Ethernet and Wi-Fi path hints no longer outrank an authenticated, secure control connection. Real connection failure, viability loss, waiting deadlines, and heartbeat failure remain authoritative. Recovery deadlines are queue-confined and tied to the exact channel, generation, and connection.
- Receive parsing and liveness are connection-scoped; stale callbacks cannot reuse a parser, refresh liveness, or mutate the replacement connection.
- iPad control readiness is separate from full booth readiness. Foreground recovery restarts only for authoritative control loss; Preview and Asset degradation recover independently.
- Asset assembly resets the current generation after corruption, retries at most twice automatically, rejects stale/session-mismatched completions, and keeps `assetUnavailable` distinct from transport corruption.
- Prompt delivery is request-driven after sources are registered for the full session lifetime. Review and strip sources follow the same recovery-safe lifetime rule.
- Remote Operator privileged HTTP control is unavailable in Release; DEBUG remains explicitly marked development-only and unencrypted.
- Operations, preflight, reconnect, degraded-preview, degraded-asset, idle, and localization states were polished only at the affected native UI seams.

Automated evidence:

- Mac complete tests: `395/395`, `0` failures, `0` skipped; iPad simulator tests: `9/9`, `0` failures, `0` skipped.
- Mac Debug/Release, iPad Debug/Release, and unsigned generic iPadOS Release compile: PASS. iPad simulator: `9FB3C107-DCA8-4D98-B9DA-A594BB232A5B`; target minimum remains iPadOS 16.0.
- Mac Thread Sanitizer test run: `395/395` PASS with zero runtime warnings; iPad simulator TSan: `9/9` PASS with zero runtime warnings.
- A loopback test drives the existing secure `BoothControlWritePump` through `10,000` ordered mixed control messages and verifies receiver-side decryption/order and zero pending queue after completion.
- `git diff --check` and the targeted transport/security regression search pass. Existing unrelated Xcode user-state and sync-conflict files remain unmodified by this work and unstaged.

Mandatory evidence not available in this environment remains explicitly open:

- 500-session integrated transport soak, 8-photo relaunch/recovery, deliberate 12-second MainActor stall, and network-failure-during-stall test.
- Instruments (Swift Concurrency, Time Profiler, Allocations, System Trace), packet capture, Device Hub GUI matrix, GitHub Actions rerun, physical private/no-internet router, Personal Hotspot, direct Ethernet/cable removal, old iPad relaunch, camera, printer, and three-hour event soak.

Release verdict: `NOT READY` until the open physical, tooling, and integrated-soak gates are completed.

## Final stability implementation pass — 2026-09-14

Starting branch: `fix/v1.4.2-stability-pairing`.
Starting SHA: `d7e1b2368a6a7d725ed8eafc6be631aa9ac90851`.
Starting dirty state: modified `PRC-PhotoBooth.xcodeproj/project.xcworkspace/xcuserdata/nont.xcuserdatad/UserInterfaceState.xcuserstate`; untracked `PRC-PhotoBooth.xcodeproj/project.sync-conflict-20260914-064337-7G5YJKM.pbxproj`. Both are machine-local and intentionally preserved.
Remote parity at start: `HEAD...origin/fix/v1.4.2-stability-pairing` = `0 0`.

Scope: complete the remaining deterministic recovery, channel-admission, MainActor, status/preflight, diagnostics, and test slices from the final event-readiness brief. Physical network, Device Hub, camera, printer, Instruments, TSan, and multi-hour soak gates remain evidence-only until actually run.

## Final event-readiness continuation — 2026-09-14

Implementation brief: `PRC PhotoBooth v1.4.2 — Final Event-Readiness Implementation Plan`.

Execution baseline:

- Branch: `fix/v1.4.2-stability-pairing`
- Starting SHA: `42612c82c432899ef723d2bb400e53e2f28dd6b3`
- Dirty files: modified `PRC-PhotoBooth.xcodeproj/project.xcworkspace/xcuserdata/nont.xcuserdatad/UserInterfaceState.xcuserstate`; untracked `PRC-PhotoBooth.xcodeproj/project.sync-conflict-20260914-064337-7G5YJKM.pbxproj`. Preserve both; do not stage.
- Toolchain: Xcode `27.0` (`27A5252f`), Swift `6.4`, macOS `27.0` (`26A5425a`), project Swift language mode `6.0`.
- Targets: macOS `15.0`; iPadOS/iOS `16.0`; iPad-only device family; marketing version `1.4.2`, build `6`.
- Baseline Mac tests: `392/392` in `56/56` suites per current release ledger; fresh `xcodebuild ... PRC-PhotoBoothTests ... test` exit `0` on this checkout.
- Baseline builds: Mac Debug, Mac Release, iPad Debug, iPad Release on simulator `9FB3C107-DCA8-4D98-B9DA-A594BB232A5B`, and unsigned generic iPadOS Release all exited `0` with isolated `/tmp/prc-photobooth-v142-baseline-*` DerivedData.
- Sub-agent review: requested read-only dispatch was unavailable because the agent thread limit was reached; equivalent local read-only review will be recorded with findings.

Scope: implement only concrete remaining software defects from the brief. Do not perform another networking rewrite. Physical, Device Hub, TSan, Instruments, packet-capture, camera, printer, app-relaunch, and multi-hour soak evidence remains mandatory and unrun unless separately exercised.

> Current release work starts from `fix/v1.4.1-stability-print-connectivity` at reviewed head `e4bef7bac0c4f7f4e713dda1b39e5b471b874cdb`. v1.4.1 is not a separate release.

## Current v1.4.2 ledger

- [x] Version/config source of truth: Mac and iPad `1.4.2 (6)`, iPadOS 16.0, iPad-only target.
- [x] Printer cancellation outcome, preflight skipped result, counter invariants, native panel flow, and Actual Size cleanup.
- [x] Unknown disk-space warning and cancellation-aware Operations refresh.
- [x] Manual LAN retry independent of a stale path-monitor sample; conservative automatic recovery retained.
- [x] Two-second peer route-discovery grace and deterministic LAN/Wi-Fi route tests.
- [x] Persistent installation identity, editable names, trusted metadata, Keychain secret storage, PIN session, QR payload, and HMAC reconnect model.
- [x] Selected-peer filtering, preferred-device reconnect policy, wrong-peer rejection, preview identity binding, and protocol version 3 compatibility state.
- [x] Mac/iPad connection settings, pairing QR scanner bridge, accessibility identifiers, and English/Thai catalog entries.
- [x] CI push triggers, Xcode 27 lane, stable macOS lane, Release artifacts, and generic iOS device Release compile.
- [x] Full local Debug/Release build matrix and complete automated suite after the pairing-regression fix: Mac tests 355/355 in 54/54 suites; iPad tests 4/4 in 1/1 suite; Mac/iPad Debug and Release builds plus generic iOS Release compile passed.
- [x] Manual final-diff simplification review and post-review test rerun; the named Ponytail skill was not available in this environment, so its requested checks were performed explicitly and documented below.
- [ ] Computer Use Mac/iPad UI pass, including native print cancellation regression.
- [ ] Real Mac↔iPad PIN/QR pairing and Ethernet/Wi-Fi fallback: pending physical/network-capable environment.
- [ ] Physical printer, camera permission, QR scan, and long-run booth cycle gate.

## v1.4.2 pairing-regression follow-up — 2026-08-31

Reviewed starting branch: `fix/v1.4.2-stability-pairing`
Starting Git HEAD: `83941dd5c487cab51e6f10e711136ecbd17c8ecf`
Final implementation HEAD: same uncommitted Git HEAD; no commit or push was requested. The pre-existing Xcode user-state change remains untouched.

Baseline before edits: `xcodegen generate` passed; Mac clean build passed; the available iOS 26.5 `iPad (A16)` simulator clean build passed with an iOS 16.0 target; Mac tests passed at 351 tests in 54 suites. Physical reproduction was not available, so the handshake stages were confirmed by code tracing before implementation.

Root causes fixed:

- Mac pairing is now rendered by `MacPairingPanel` inside the Settings network page. The Operator window no longer owns a competing pairing sheet.
- Pending/incoming iPads are presented separately from `trustedPeers`; trust is not stored until reciprocal HMAC authentication succeeds.
- Pairing intent, session, request, result, auth challenge, and auth proof sends now use completion-aware control sends. Failures become visible state and reconnect/retry behavior.
- iPad intent/session/request/provisional-result state has a local, session- and generation-guarded expiry task.
- Centralized cleanup clears ephemeral pairing, auth, target, expiry, and connection state without deleting persistent trusted peers. Connection and pairing generations reject stale callbacks.
- A rejected second peer and a Mac cancel/expiry received before PIN entry no longer disturb or strand the active pairing attempt.

Affected implementation files:

- `Shared/Connectivity/NetworkBoothTransport.swift`
- `Shared/Connectivity/BoothPairing.swift`
- `Shared/Connectivity/BoothTransport.swift`
- `Mac/UI/MacContentView.swift`
- `iPad/UI/iPadConnectionSettingsView.swift`
- `Tests/BoothPairingTests.swift`
- `Tests/MessageTests.swift`

Verification ledger:

- Mac Debug build: PASS.
- Mac Release build: PASS.
- iPad Debug build: PASS on the available iOS 26.5 `iPad (A16)` simulator; compiled target remains iOS 16.0.
- iPad Release build: PASS on the available iOS 26.5 `iPad (A16)` simulator.
- Generic iOS Release build with `CODE_SIGNING_ALLOWED=NO`: PASS; target triple `arm64-apple-ios16.0`.
- Mac automated tests: PASS, 355 tests in 54 suites.
- iPad automated tests: PASS, 4 tests in 1 suite.
- Version/config audit: PASS, marketing version `1.4.2`, build `6`, iPad-only family `2`, iPad minimum `16.0`, macOS minimum unchanged at `15.0`, protocol `3`.
- Caveman review: PASS; the underlying pairing state/transport lifecycle was repaired, with no secret/PIN/token/proof/nonce logging.
- Ponytail review: named skill unavailable; equivalent manual review completed for duplicate owners/state, cleanup, dead paths, security, and scope.
- Computer Test/Use: NOT RUN as a formal gate. The built Mac app launched, but host accessibility access/display capture was unavailable. The built iPad app installed/launched in the simulator and rendered its customer screen, but no touch/accessibility driver was available for the Settings pairing flow.
- Physical iPad Wi-Fi pairing: PENDING; no physical iPad was available.
- Physical Ethernet and Wi-Fi fallback: PENDING; no hardware/network-capable booth was available.

Hardware-dependent items remain release blockers until exercised on the real Mac/iPad pair.

## Pairing history comparison — 2026-09-01

The reported GitHub window has no 30 October commits. The matching historical
window is 30 August 2026, 22:00–23:59 (+07:00): `1963d6225cc749f2c9272fd803f6a6a18f0e2f86`
and `234519ae37f4099bb683c373df91ee49344d5ae7`. That build used the
Mac-started, Bonjour-advertised pairing session directly: iPad opened PIN entry
and submitted its pairing request without first requiring a `pairingIntent`
round trip. The subsequent `479ae6f28f379044634c33b433c9da8cb9edb704` change
introduced the automatic iPad intent/session flow.

The current implementation retains the intent flow when no Mac session is
advertised, but restores the established direct PIN path when a discovered Mac
advertises a complete, unexpired pairing session. Session ID, expiry, PIN, and
HMAC validation remain Mac-authoritative. `BoothPairingTests` passed 21/21 and
the iPad Debug simulator build passed. Physical verification remains pending:
no physical iPad is attached to this development Mac.

## Release blockers

Do not mark this release ready while an automated build/test gate fails, an unknown peer can auto-connect, trust is not Keychain-backed, printer cancellation reports Passed, manual LAN retry is monitor-gated, or a production secret appears outside Keychain. GUI, camera, LAN, printer, and long-run items remain explicitly pending until exercised.

---

## v1.4.2 Large Event Stability & Security Hardening — 2026-09-13

Mission: keep Mac-to-iPad booth control healthy during sustained physical-event workload while preserving iPadOS 16, macOS 15, Swift 6, XcodeGen, versioned Keychain-backed trust, and the existing transport abstraction. The secure pairing wire is protocol v4.

Execution baseline:

- Branch: `fix/v1.4.2-stability-pairing`
- Local start SHA: `cd7464397c0d57214000ba3428c844bc3d5fe55f`
- Fetched remote branch: `a3c55a208de45c77ac89b65717739940237ae3a7` (local branch behind three commits; no integration performed)
- Dirty files existed before this work, including pairing/transport/UI/localization, generated Xcode project/user state, task ledgers, and capture-framing files. Preserve them unless a later change is explicitly in scope.
- Baseline `xcodegen generate`: PASS.
- Baseline builds: Mac Debug/Release PASS; iPad Debug/Release PASS on Device Hub iPad Pro 13-inch (M5), iOS 27.0; generic iOS Release PASS.
- Baseline tests: Mac `365/365` in `55` suites PASS; iPad `7/7` PASS. Existing compiler/test warnings and LMDB `MDB_MAP_FULL` diagnostics remain recorded, not treated as product failures.
- Physical and GUI gates: not run; no physical iPad, printer, camera, Ethernet adapter, hotspot, or reliable host accessibility driver available.

Architecture decisions:

- Extend `NetworkBoothTransport` and `BoothConnectionStatus`; do not create a parallel control transport or pairing store.
- Keep UI/status publication on MainActor, but confine socket callbacks, frame parsing, heartbeat timing, reconnect policy, and preview coalescing to a dedicated serial transport executor unless current SDK annotations prove an actor is safe.
- Local Network mode (`.wifi`) means unconstrained local connectivity, including Wi-Fi, hotspot, router LAN, Mac Ethernet uplink, and peer-to-peer. Direct Ethernet (`.lan`) remains wired-only.
- Use protocol v4 for the secure pairing wire; the app-layer Curve25519/HKDF/HMAC path is compatible with the targets, while operational channel confidentiality remains blocked until a native TLS/PSK path is proven. Never transmit a long-term secret or invent cryptography.
- Keep Remote Operator disabled by default and never reveal its pairing token from unauthenticated `/operator`.
- Prefer deterministic pure policy tests and existing test suites over a production DEBUG-only state fork.

Ordered slices:

1. Observability contract: extend `OperationsEventStore`, diagnostics models/export, and redaction tests for transport transitions, send failures, reconnects, route/path, and queue health.
2. Transport executor: move Network.framework callbacks/starts, receive parsing, heartbeat timestamps, reconnect scheduling, and preview coalescing off MainActor; retain immutable MainActor publication and ordered writes.
3. Route/recovery policy: remove `.wifi` physical-interface restriction, add path labels, bounded `.waiting`/viability recovery, and stale-generation tests.
4. Lifecycle/control reliability: handle iPad scene phase and idle timer, preserve authoritative Mac state, make critical sends explicit, and test resync after uncertain delivery.
5. Pairing/security gate: audit the bootstrap, reject raw long-term-secret serialization, and use the versioned native Curve25519/HKDF/SAS path only where SDK compatibility is proven; document the native TLS/PSK blocker and retain private-network restriction until operational confidentiality is closed.
6. Remote Operator/server: safe-by-default operator routing, token non-disclosure, one-time auth/revoke behavior, request deadline, connection bound, slow-client protection, and security headers.
7. Queue/finalization: choose oldest runnable critical work across sessions, keep optional GIF/cloud work bounded, and isolate safe CPU/disk work from transport/UI.
8. Preflight/UI: extend existing readiness/diagnostics and affected Mac/iPad connection states with accurate route/auth/control/preview status, accessibility identifiers, and complete English/Thai copy.
9. Soak/QA: add deterministic failure-injection seams and DEBUG-only accelerated workload hooks; run automation after each slice, then report Device Hub and physical gates separately.

Checkpoint criteria:

- After slices 1–3: transport tests, route tests, framing/pairing/message tests, Mac/iPad builds pass; no production Network.framework object starts on `.main`.
- After slices 4–6: lifecycle, control, pairing, operator-auth, HTTP parser/server tests and both app builds pass; no secret appears in logs or unauthenticated operator responses.
- After slices 7–9: queue/render/server/preflight/UI tests and final build matrix pass; remaining physical gates are explicitly `BLOCKED-HARDWARE` unless exercised.

Release risks:

- Network.framework Sendable/API availability may block an actor implementation; use a serial executor or stop at a documented compatibility boundary rather than scatter `@unchecked Sendable`.
- Native TLS PSK behavior on iPadOS 16 may not support the proposed bootstrap; do not replace it with homemade encryption.
- Generated project/user-state and localization files may be dirty from prior work; never stage or overwrite them for convenience.
- Local builds cannot prove hotspot, Ethernet, camera, printer, accessibility, thermal, or multi-hour behavior.

## Final execution status — 2026-09-13

Implemented and verified: bounded redacted transport diagnostics; serial Network.framework I/O/parser/heartbeat/reconnect/preview work behind the existing MainActor facade; unconstrained `.wifi` route semantics with direct Ethernet preserved; bounded recovery and iPad lifecycle handling; explicit critical send outcomes; v4 secure pairing with ephemeral Curve25519/HKDF/HMAC, transcript-bound SAS, and HMAC-authenticated Mac confirmation; default-off Remote Operator with bounded HTTP handling and security headers; cross-session critical queue fairness; bounded worker execution for image/GIF/thumbnail work; extended preflight/diagnostics/UI/localization/accessibility.

Automated final gates: Mac 375 tests in 55 suites; iPad 7 tests in 1 suite; Mac Debug/Release; iPad Debug/Release simulator; unsigned `iphoneos` Release; all passed. `git diff --check` passed.

Remaining release blockers: native operational TLS/PSK is not available in the local macOS 15/iPadOS 16 Network.framework headers and no homemade replacement was added; TSan/soak are not run; Computer Use GUI and all physical Wi-Fi/hotspot, Ethernet, camera, QR-scan, printer, and multi-hour gates remain unavailable. Release verdict: NOT READY.

Operational confidentiality boundary: the current residual-risk deployment assumes a private, operator-controlled venue LAN with Remote Operator disabled unless explicitly enabled. The app-layer pairing handshake authenticates the selected Mac/iPad and requires matching SAS confirmation, but Network.framework control/preview payloads are not encrypted against a malicious same-LAN observer or active MITM. Native TLS/PSK support must be proven on the minimum targets before treating that threat as closed; homemade encryption is intentionally out of scope.

## Final event hardening continuation — 2026-09-13

This amendment records the current implementation and supersedes older v1.4.2
notes where they conflict. The generated Xcode project and local Xcode user
state remained untouched for delivery; `project.yml` remains the source of
truth.

Implemented software slices:

- Protocol v5 is required by both apps. The authenticated operational channel
  uses a transcript-bound CryptoKit ChaChaPoly secure channel with directional
  control/preview/asset keys, role-bound associated data, monotonic counters,
  and replay rejection.
- Control messages now carry bounded metadata and asset references. Asset
  chunks are independently framed, hashed, size-limited, out-of-order safe,
  and bounded to 16 concurrent assemblies and 32 MiB buffered data.
- Mac completion is authoritative for session rollover. The iPad sends
  `customerFinished`, waits for the Mac's idle sync, and no longer locally
  invents completion or shows stale session media.
- Critical sends expose completion outcomes; route/path/viability and
  redacted send/reconnect diagnostics are persisted through the existing
  Operations event path.
- iPad active/background handling, idle-timer policy, request deadlines,
  review/recovery state cleanup, and capture-recovery retake behavior are
  covered in the existing architecture.

Final automated evidence:

- Mac tests: 383 tests in 55 suites passed with `xcodebuild ... PRC-PhotoBoothTests ... test`.
- iPad tests: 7 tests in 1 suite passed with `xcodebuild ... PRC-PhotoBooth-iPadTests ... test`.
- Mac Debug and Release builds passed.
- iPad Debug and Release simulated-device builds passed.
- Unsigned generic iPad Release compile passed for `arm64-apple-ios16.0`.
- Focused Message/Capture Recovery run: 19 tests in 2 suites passed.
- `git diff --check` passed.

### Required failure matrix

| Issue | Root cause / owner / files | Software evidence | Physical or integration evidence | Final status |
|---|---|---|---|---|
| P0-SESSION-NEXT | iPad previously reset locally; owner `BoothCoordinator` + `iPadViewModel` + `Message.swift`. | Authoritative `customerFinished`/idle-sync path; 500 state-machine rollover test; full Mac/iPad tests. | Three real sequential customers and reconnect rollover not run. | SOFTWARE PASS; event workflow pending |
| P0-TRANSPORT-MAINACTOR | Network transport facade and lifecycle still belong to `@MainActor`; parser/callback work uses `transportQueue`. Owner `NetworkBoothTransport.swift`. | Mac/iPad builds and transport/framing suites pass. | No 12-second MainActor stall test, TSan, or Instruments trace. | PARTIAL; known P0 ceiling |
| P0-HEARTBEAT-RACE | Queue-confined monotonic heartbeat state was added, but close/lifecycle publication still crosses the MainActor facade. Owner `NetworkBoothTransport.swift`. | Heartbeat/framing tests and full Mac suite pass. | Stale-timeout race under a stalled UI and generation integration test not run. | PARTIAL |
| P0-PAYLOAD-BUDGET | Binary media had been embedded in control messages. Owner `Message.swift`, `BoothTransport.swift`, `ExperienceTypes.swift`. | 128 KiB target / 256 KiB hard control ceiling, asset encode/reassembly tests, 383-test suite. | Live workload/frame capture not run. | SOFTWARE PASS |
| P1-IPAD-IDLE-TIMER | Idle timer policy was not tied to the kiosk's active lifecycle. Owner `iPadApp.swift`. | Source/build and iPad smoke suite pass. | Physical idle-screen test not run. | SOFTWARE PASS |
| P1-FOREGROUND-STALE | Preview/state could remain trusted after suspension. Owner `iPadViewModel.swift`. | Active/background cleanup and freshness checks compile and pass smoke tests. | Physical background/foreground reconnect not run. | SOFTWARE PASS; device pending |
| P1-PATH-AUTHORITY | Monitor samples were treated as route truth. Owner `NetworkBoothTransport.swift`. | Actual connection path, viability, waiting recovery, and route tests pass. | Wi-Fi/hotspot/Ethernet flapping not run. | SOFTWARE PASS; network pending |
| P1-STRIP-PRIVACY | Finished media was retained across session boundaries. Owner `BoothCoordinator.swift` + `iPadViewModel.swift`. | Session-scoped asset references and cleanup are implemented; full suite passes. | Dedicated stale-customer media integration/privacy test and physical workflow not run. | IMPLEMENTED; dedicated gate pending |
| P1-SYNC-TRANSIENT-STATE | Authoritative sync did not clear pending customer UI state. Owner `iPadViewModel.swift`. | Sync now clears pending requests, preview, asset assembler, and old maps; iPad tests pass. | Reconnect during each customer phase not run. | SOFTWARE PASS |
| P1-START-TIMEOUT | Customer start could wait indefinitely on an uncertain send. Owner `iPadViewModel.swift` + `BoothCoordinator.swift`. | Completion callbacks and bounded request timeout paths compile; full suite passes. | Network fault-injection run not available. | IMPLEMENTED; fault injection pending |
| P1-CRITICAL-SEND | State transitions could precede transport completion. Owner `BoothTransport.swift`, `NetworkBoothTransport.swift`, `BoothCoordinator.swift`. | Completion-aware session preparation and authoritative review decisions; send diagnostics; full builds/tests. | End-to-end delayed-send integration not run. | SOFTWARE PASS; integration pending |
| P1-DIRECT-LAN-SCOPE | Fixed direct-Ethernet probing could leak into Local Network mode. Owner `NetworkBoothTransport.swift` + route policy. | Preference/path tests and direct-LAN guard pass. | Direct Ethernet and hotspot matrix not run. | SOFTWARE PASS; network pending |
| P1-PREVIEW-MAINACTOR | Preview decode/coalescing risked blocking UI work. Owner `NetworkBoothTransport.swift` + `iPadViewModel.swift`. | Coalescing/transport changes compile and existing preview tests pass. | 30 FPS physical preview and MainActor stall trace not run. | PARTIAL |
| P1-PHYSICAL-ROUTE-DIAGNOSTICS | Operators lacked actual route/viability evidence. Owner transport diagnostics + Operations store. | Redacted route/viability/send diagnostics compile and persist. | Physical route evidence not available. | SOFTWARE PASS; physical pending |
| SEC-OPERATIONAL-CONFIDENTIALITY | Pairing authentication did not protect operational payloads. Owner `BoothPairing.swift` + transport. | CryptoKit AEAD, directional keys, transcript binding, counter/replay tests pass; no raw secret serialization. | No packet capture or active-MITM test. | SOFTWARE PASS; live security validation pending |
| SEC-REMOTE-OPERATOR | Remote Operator exposure required safe defaults and bounded HTTP behavior. Owner existing operator server/auth. | Existing HTTP/security regression tests remain green; default-off behavior preserved. | No live server audit. | SOFTWARE PASS |
| SEC-PAIRING-REGRESSION | Pairing needed v5 rejection and secure-channel regression coverage. Owner pairing/transport/message. | v5 compatibility, ephemeral agreement, SAS/secure-channel, and pairing tests pass. | Real PIN/QR/wrong-device pairing not run. | SOFTWARE PASS; physical pending |
| PERF-QUEUE-FAIRNESS | Optional rendering/cloud work could starve required finalization. Owner existing session queue. | Queue fairness and cancellation tests pass in the 383-test suite. | No multi-hour production queue load. | SOFTWARE PASS |
| PERF-RENDER-MAINACTOR | Render/thumbnail work needed isolation from UI/transport. Owner existing render pipeline. | Existing compositor/queue tests and Release builds pass. | Instruments/Time Profiler not run. | PARTIAL |
| QA-SOAK | A deterministic 500-message check was not equivalent to 500 full sessions. Owner state/session tests. | Added 500 sequential one-photo state-machine sessions plus existing 500-message gate. | No 500 network/capture/print/render sessions. | PARTIAL |
| QA-PHYSICAL | Camera, printer, routes, Device Hub GUI, and physical soak require equipment. | Automated software matrix is green. | No physical iPad Pro 9.7, router, hotspot, Ethernet, camera, printer, GUI, or 3-hour soak. | NOT RUN |

Known ceilings that keep the release verdict below event-ready:

- `NetworkBoothTransport` remains a MainActor-owned facade/lifecycle around
  its serial transport executor; the required MainActor-stall proof is absent.
- Asset chunks currently use the authenticated control `NWConnection` with a
  logical asset channel. A dedicated asset TCP service/port and independent
  head-of-line proof were not added.
- No TSan, Instruments, live packet capture, or physical/network matrix was
  available in this environment.

Release verdict: `NOT READY`.

## Final event-readiness delivery amendment — 2026-09-14

This amendment supersedes the older continuation above where it conflicts.
Delivery implementation commit: `30f1645`.

Implemented software gates:

- Protocol 6 and `asset-channel-v2`; incompatible peers receive the exact update-both-apps error.
- Mac-authoritative secure negotiation with bounded 5s generation-aware timeout and deferred early hello.
- One FIFO 256-message/4 MiB control writer, encrypted heartbeat path, and independent bounded asset writer.
- Bonjour `_prc-asset._tcp`, direct Ethernet port 58502, encrypted asset channel binding, dependent-channel invalidation, asset-only recovery, and bounded missing-asset requests.
- Mac-authoritative customerFinished/idle sync, transient request cleanup, and validated session-scoped asset recovery.
- Local-wireless route remains unconstrained; direct Ethernet remains `.lan` only; legacy heartbeat no longer uses a run-loop timer.

Automated evidence on this tree:

- `xcodegen generate`: PASS.
- Mac tests: 387/387 in 55/55 suites.
- iPad tests: 7/7 in 1/1 suite.
- Mac Debug/Release: PASS.
- iPad Debug/Release simulator: PASS.
- Unsigned generic iOS Release: PASS, `arm64-apple-ios16.0`.
- `git diff --check`: PASS.

Not run / release blockers:

- No TSan, Instruments, packet capture, deterministic 12s MainActor-stall proof, 10k writer stress, deterministic integration harness, 500 network/capture/print session soak, Device Hub GUI, physical Wi-Fi/hotspot/Ethernet/camera/QR/printer, app-relaunch matrix, or 3-hour physical soak.
- `NetworkBoothTransport` and asset receive still have MainActor ownership/processing ceilings; preview writer progression remains on the facade.
- Native TLS/PSK compatibility on minimum targets remains unproven; Remote Operator stays default-off with the existing HTTP boundary.

Release verdict: `NOT READY`.

# Historical: PRC PhotoBooth — v1.3 Reliability Hardening

> The PR #7 stabilization plan below is historical context. Current work is on `feature/v1.3-reliability-hardening`.

## Current task: network, GIF delivery, downloads, and staged previews

Starting SHA: `b6bcbd72e9803123bc20615bcd41b5a18a9a8ce6`

### Dependency graph

```text
route policy ────────────────> NetworkBoothTransport ──> network tests
GIF state + quality model ───> queue/routes/guest UI ──> delivery tests
quality model + compositor ──> TemplateGIFRenderer ───> render/benchmark tests
route validation ────────────> LocalDownloadRouter ───> streaming server tests
staging resolver ────────────> editor preview/save ───> editor tests
```

### Ordered slices

1. Preference-aware route discovery and stale-generation coverage.
2. Explicit GIF availability state and queue/guest progressive behavior.
3. Compact/Balanced/High quality persistence and operator selector.
4. Production renderer integration coverage and bounded render memory.
5. Streaming media responses, file-size UI, atomic publication checks.
6. Staged foreground preview and save/preview transaction handling.
7. Full tests, four build configurations, Computer UI flow, benchmarks, and final review.

### Checkpoints

- After slices 1–3: focused network/GIF tests and Mac/iPad builds.
- After slices 4–6: renderer/server/editor tests and Mac build.
- Final: complete suite, Mac/iPad Debug + Release, UI/manual checks, integrity and failure tests.

### Known baseline constraints

- Existing dirty signing, localization, and Xcode-user files are preserved and are not part of this task.
- The baseline suite has one known failure for a missing Thai localization entry in the pre-existing dirty `Mac/Localizable.xcstrings` change.
- Physical Sony/iPad LAN validation is hardware-dependent; no result will be claimed without hardware.

## Current reliability-hardening status

- Startup health now records runtime, SwiftData, queue, recovery, experience, and local-server failures; required persistence/server failures block readiness without crashing the UI.
- DSLR capture readiness is independent from AVFoundation permission; AVFoundation is reported as optional preview health when DSLR capture is selected.
- Session-sensitive control messages carry the session UUID and a Mac-issued sequence; iPad reconnect sync is authoritative and stale packets are rejected.
- Normal state-machine events are guarded; recovery and remote sync use explicit authoritative-restore APIs.
- Countdown capture and rendering use one transmitted absolute deadline.
- Automated validation: Mac/iPad Debug and Release builds pass; 213 tests run, 212 pass, with one pre-existing Thai localization failure.
- Computer Use launch was attempted, but the environment returned `cgWindowNotFound` for app windows; visual interaction remains pending.

## v1.3 implementation status

- Capture Recovery state/actions: implemented for retry receive, retake, deferred indices, and previous-photo fallback.
- Capture attempt isolation: implemented with IDs and terminal task cleanup in the DSLR source.
- Network transport: production `NetworkBoothTransport` with framed control/preview channels, Bonjour, heartbeat, reconnect, and session sync; legacy Multipeer remains DEBUG-only fallback.
- Operations: health snapshot, bounded event log, printer metrics, delivery resolver, authenticated remote operator API/dashboard, and LAN sharing station.
- Verification: deterministic state, framing, HTTP, auth, gallery/privacy, delivery, and legacy-manifest tests are required before release; physical Sony and interactive GUI checks remain environment-dependent.

---

# Historical: PR #7 Stabilization and External Display Plan

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

## v1.4 Operator Experience & Connectivity

Starting point: `feature/v1.3-reliability-hardening` at `ef8a9556bced1920615042a27590e9811be50a69`.

Implementation slices:

1. Fix wired LAN attempt state; add bounded production network/preview diagnostics and route tests.
2. Add a bounded dedicated review-image encoder; keep historical thumbnails small; make iPad Review responsive; add preview-quality policy tests.
3. Use macOS system printing only; reorganize Settings with top navigation and move PIN reset to Security.
4. Make Operations collapsible.
5. Add native Event Setup and frame-editor multi-selection, batch deletion, group operations, keyboard actions, and undo/redo.
6. Bump both targets to 1.4 through `project.yml`, regenerate, run all builds/tests, manually test with Computer Use and physical iPad when possible, clean temporary test events, and review the final diff.

Acceptance gates: no initial Ethernet fallback, framed review messages stay below the 2 MiB payload limit, historical sync remains small, Mac/iPad/tests build separately, `git diff --check` is clean, and all hardware-only limits are reported honestly.

## v1.4 operator experience/connectivity completion

Baseline was recorded on feature/v1.4-operator-experience-connectivity at
60d9c7b99898940e52f8c22708db75c324e52f4a; the worktree already contained
unrelated localization and Xcode user-state changes, which remain preserved.

Completed implementation slices:

- [x] Staged Guest Experience Save/Back transaction; preview rebuild is now a post-save warning path.
- [x] Operations section severity summaries and persistent collapsed-header indicators.
- [x] Coordinator/store-owned single-active-event changes, including nil deactivation.
- [x] Frame-editor Undo/Redo selection-anchor restoration and stale-anchor validation.
- [x] Guest Experience single-pass 24 pt horizontal/top spacing.
- [x] LAN preview/control peer identity regression guard; existing route fallback coverage retained.

Existing regression coverage remains green for printing, review-image reconnect,
and Preview Quality. The final suite ran 287 tests in 48 suites: 286 passed
and one pre-existing Thai localization failure remains in the dirty
Mac/Localizable.xcstrings catalog (the Auto preview-route description). Mac/iPad
Debug and Release builds passed.
Computer Use launched the Mac app but UI interaction was blocked when the
native accessibility pipe closed. Physical iPad, Ethernet, Sony, printer,
and display checks are hardware-dependent and remain unrun.

## Final event-readiness closure — 2026-09-14

Starting branch: `fix/v1.4.2-stability-pairing`.
Starting SHA: `f49382b7bab62786bc3a9e2e9f304d4be23f1464` (`Fix v1.4.2 event readiness`).
Dirty state preserved before work: modified machine-local
`PRC-PhotoBooth.xcodeproj/project.xcworkspace/xcuserdata/nont.xcuserdatad/UserInterfaceState.xcuserstate`;
untracked `PRC-PhotoBooth.xcodeproj/project.sync-conflict-20260914-064337-7G5YJKM.pbxproj`.
No branch switch, reset, clean, restore, or stash permitted.

Immutable configuration: Xcode `27.0`; Swift `6.4` / project language mode `6.0`;
macOS `15.0`; iPadOS `16.0`; iPad-only target; marketing version `1.4.2`, build `6`.
`project.yml` remains XcodeGen source of truth.

Current remote CI evidence: workflow run `34806079207` for this SHA failed only at
`Upload macOS app artifact`; package/path/name validation passed, exact upload error
was `Failed to CreateArtifact: Unable to make request: ENOTFOUND`. iPad artifact
upload and Stable macOS lane passed. Root cause currently localizes to runner
artifact-service DNS/endpoint access; no workflow correction is proven yet.
Final-SHA CI run 34813252769 for 0ff869e passed all three lanes: Build macOS app,
Build iPad Simulator app, and Stable macOS lane. Mac and iPad artifact uploads
also passed; no workflow change was required.

Historical current-tree ledger totals: Mac `392/392`; iPad `9/9`. Fresh baseline
matrix is required before source edits. Remaining P1: asset retry recovery across
fresh verified Asset-channel generations. Outstanding gates: deterministic 500-session
soak, 8-photo relaunch restore, 12-second MainActor stall, network failure during
stall, secure-writer stress rerun, TSan, Instruments, Device Hub, physical router/
hotspot/Ethernet, camera, QR/PIN, printer, old-iPad relaunch, and three-hour soak.

Execution order:

1. Baseline project generation, builds, tests, and diff validation.
2. Asset retry recovery epoch fix plus focused tests.
3. Re-run focused/full automation; preserve CI YAML unless a proven workflow defect appears.

Final evidence recorded for this closure:

- Fresh baseline before source edits: xcodegen generate, Mac Debug/Release,
  Mac 395/395 in 56 suites, iPad Debug/Release, iPad 9/9, unsigned
  generic iOS Release, and git diff --check all passed.
- Asset retry A-H coverage passes in the iPad suite: bounded two-retry
  per-generation behavior, fresh-generation recovery, duplicate/stale ready
  protection, two-generation global ceiling, success/session cleanup, localized
  recovery copy, and the 30-reference ordered/bounded pump.
- Final automation: Mac 397/397 in 57 suites; iPad 18/18 in 2 suites;
  Mac/iPad Debug and Release builds plus unsigned generic iOS Release passed.
  The existing secure Control writer test delivered 10,000 ordered messages.
- Deterministic stress coverage passes for 500 synthetic customer sessions and
  an 8-photo authoritative relaunch/asset-assembly path. The exact 12-second
  MainActor-stall and network-failure-during-stall gates remain unrun because
  the hosted Mac app test target restarts when its MainActor is deliberately
  blocked; no flaky replacement is counted as release evidence.
- Mac and iPad Thread Sanitizer test runs passed with no reported TSan race
  diagnostics. Instruments templates are installed, but no event-workload
  Time Profiler/Swift Concurrency/Allocations trace was captured.
- Current v1.4.2 documentation uses protocol 6 and the authenticated
  CryptoKit directional channel already present in the source. Earlier
  TLS/PSK, protocol-3, and simulator-only statements remain historical audit
  entries and are superseded by this closure; they are not current
  implementation requirements. The generic iOS Release build proves device
  compilation only; Device Hub GUI and physical-device evidence remain
  explicitly unrun.
- Final-SHA GitHub Actions run 34813252769 passed for commit 0ff869e; all
  required CI lanes and artifact uploads are green.

4. Add only production-path deterministic failure-injection coverage that current architecture can support.
5. Review affected UI with Impeccable/frontend-design native constraints.
6. Update factual release ledger and report `READY FOR EVENT` only after every mandatory gate passes.
