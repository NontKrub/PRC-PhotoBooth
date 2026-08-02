# Implementation Plan: PRC PhotoBooth 1.1 Reliability and Operations

## Overview

Add restart-safe session manifests and workspaces, a persistent single-worker job queue, recovery and QR restoration, correct retake persistence, queued cloud/print work, preflight diagnostics, and an operator Operations tab while preserving the existing Mac-authoritative architecture and wire protocol.

## Architecture Decisions

- Runtime JSON is the recovery source of truth; existing SwiftData models remain unchanged.
- Accepted JPEGs and GIF source frames are written before the state machine advances.
- Queue execution is serial and idempotent by `sessionID + job kind`; required jobs gate guest completion, optional jobs do not.
- Local download tokens resolve directly to persisted absolute session directories so output-root changes do not break old links.
- Existing AppKit, Network, SwiftData, compositor, GIF encoder, and MultipeerConnectivity code remain the platform primitives.
- New files are picked up through `project.yml`; generated Xcode project files are never hand-edited.

## Task List

### Phase 1: Runtime persistence foundations

- [ ] Add manifest models/store with atomic JSON persistence and corrupt-file reporting.
- [ ] Add session workspace creation, safe event names, atomic accepted-shot writes, frame snapshot, and image loading.
- [ ] Add focused manifest/store/workspace tests.

### Phase 2: Accepted capture and data correctness

- [ ] Add DataStore session lookup/restore/delete and shot upsert helpers.
- [ ] Create workspace + manifest during session start, including event snapshot and token.
- [ ] Persist Keep before state advancement; route guest/operator retakes through one counter path.
- [ ] Extend state-machine restoration and add retake/recovery behavior tests.

### Checkpoint: Capture persistence

- [ ] Mac build and full test suite pass.
- [ ] Existing capture flow still compiles and preserves Multipeer messages.

### Phase 3: Persistent queue and job execution

- [ ] Add job models, retry policy, atomic queue store, and startup repair.
- [ ] Add serial queue service and executor with required-job priority/dependencies.
- [ ] Move strip/GIF/download registration into queued jobs; reconcile completion idempotently.
- [ ] Add queue store and queue execution tests.

### Phase 4: Downloads, cloud, and printing

- [ ] Make local server state/token mappings persistent-source compatible and secure; add health route.
- [ ] Restore valid QR mappings on startup.
- [ ] Extract structured cloud upload service with retries and `.work` exclusion.
- [ ] Add AppKit printer service, test page, settings, automatic-print queue path, and retry state.

### Phase 5: Recovery and operations

- [ ] Add startup recovery classification, Resume/Discard, and finalizing-session job repair.
- [ ] Add preflight models/service with safe/full checks and readiness calculation.
- [ ] Add Operations tab, recovery/queue/printer/server panels, readiness banner, and start gating.
- [ ] Add focused recovery, router, preflight, and printer tests where platform seams permit.

### Phase 6: Cleanup and release

- [ ] Update cleanup, version metadata, README, and recovery limitation documentation.
- [ ] Run Mac/iPad builds, full tests, diff review, and manual checks that hardware permits.
- [ ] Commit intentional slices, push branch, and open a draft pull request.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Swift 6 actor isolation around `CGImage` and AppKit | High | Keep UI services `@MainActor`; perform file/image work in existing Mac target patterns; compile after each slice. |
| Existing DataStore singleton and generated model behavior | High | Add methods only; do not add model types/properties; use manifest restoration for missing records. |
| Network listener readiness is asynchronous | Medium | Track explicit server state and expose health/status; restore mappings after startup. |
| Physical camera/printer unavailable in CI | Medium | Keep checks behind existing services and add deterministic platform-boundary tests. |
| Existing unrelated xcuserdata change | Low | Never stage it; use explicit paths for commits. |

## Open Questions

- None blocking. When existing code conflicts with the requested contract, the requested Version 1.1 behavior takes precedence while preserving the current wire format.
