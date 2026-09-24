# Large-event code and security audit — 2026-09-22

Verdict: **NOT READY FOR A LARGE EVENT**.

Reviewed checkout: `fix/v1.4.3-release-hardening`, HEAD `972191f1827e983bb4c78372687243c815b18961`.
This is an audit, not a remediation change. Application source was not modified. Existing generated Xcode project edits, user state, and the sync-conflict project file were preserved.

The repository contains 112 production Swift files and 39,649 Swift source lines across Mac, iPad, and Shared. Review covered the session lifecycle, transport/authentication, HTTP serving, camera capture, rendering, job execution, persistence/recovery, cloud upload, printing, gallery delivery, and their UI entry points and tests. Targeted source tracing and syntax parsing do not establish that every defect has been found. Hardware and sustained-event behavior remain separate acceptance work.

P1 means a release-blocking security, data-safety, or event-continuity defect under the stated trigger. P2 means a significant conditional or delivery defect. Findings below are source-confirmed unless a runtime probe is explicitly identified.

## Findings

### F01 — P1: An unauthenticated TCP connection can block the real iPad

**Location:** [Shared/Connectivity/NetworkBoothTransport.swift:2403–2415](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Shared/Connectivity/NetworkBoothTransport.swift:2403), `2737–2744`.

The Mac reserves its single Control connection before authentication and rejects every later connection while that socket exists. A client that completes TCP and then sends nothing has no pre-authentication deadline. The LAN handshake timer is iPad-only; the secure-channel timer and heartbeat start later in the authenticated flow.

**Trigger and impact:** A device that can reach the advertised Control service opens an idle connection while the legitimate iPad is disconnected. Pairing and reconnect attempts are rejected indefinitely. No pairing secret is required.

**Smallest correction:** Start a generation-bound authentication deadline on every accepted Control socket. Close an unauthenticated socket when that deadline expires; cancel the timer only when authentication completes or the socket closes.

**Required check:** An idle unauthenticated connection expires, and a legitimate iPad can subsequently authenticate without restarting the Mac app.

### F02 — P1: DSLR recovery can return another guest's photograph

**Location:** [Mac/Camera/DSLRCameraSource.swift:384–429](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Camera/DSLRCameraSource.swift:384), `1082–1124`.

`recoverLastCapture()` starts a new attempt, clears the pre-capture media baseline, and falls back to the last camera object or latest catalog file. The new attempt ID proves that a callback belongs to the recovery operation; it does not prove that the camera object belongs to the failed guest capture.

**Trigger and impact:** The shutter fails or produces no new object while the card contains an earlier photograph. Retry Receive can download that earlier photograph into the current session. This is both output corruption and a cross-guest privacy risk.

**Smallest correction:** Retain the original capture's object identity or pre-shutter object baseline across recovery. If ownership cannot be established, report no recoverable image and require a retake.

**Required check:** Seed an old camera object, simulate a failed shutter with no new object, then retry receive. The old image must never become the current guest's capture.

### F03 — P1: Diagnostic capture can orphan an active guest capture

**Location:** [Mac/Camera/AVFoundationCameraSource.swift:234–244](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Camera/AVFoundationCameraSource.swift:234); [Mac/UI/OperationsView.swift:367–370](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/OperationsView.swift:367); [Mac/Diagnostics/BoothPreflightService.swift:86–90](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Diagnostics/BoothPreflightService.swift:86).

AVFoundation capture stores one continuation without checking for an existing capture. Full Preflight remains available during a live session and calls the same camera path. A second request overwrites the first continuation; a photo callback can satisfy the wrong caller while the other caller never resumes.

**Trigger and impact:** Run Full Preflight while a guest still is being captured, or overlap diagnostic requests. The guest session can hang, and the returned photograph can be assigned to the wrong operation.

**Smallest correction:** Reject overlapping capture requests in the camera source, which owns the shared continuation. Also disable diagnostic shutter actions during active guest capture. Terminal failure, stop, and cancellation must resolve the pending request exactly once.

**Required check:** Overlap a diagnostic capture and a guest capture. One must fail as busy, and the other must complete with its own result.

### F04 — P1: The DSLR timeout can remove the last remaining deadline

**Location:** [Mac/Camera/DSLRCameraSource.swift:370–379](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Camera/DSLRCameraSource.swift:370).

When the 30-second capture timeout fires, it starts an ImageCaptureCore catalog download and returns if a fresh file was found. That asynchronous download has no replacement capture deadline.

**Trigger and impact:** The fallback download is accepted but its callback never arrives. Capture remains pending indefinitely instead of entering recovery.

**Smallest correction:** Keep a bounded deadline through the fallback download and terminate the same capture attempt when it expires.

**Required check:** Accept the fallback download without delivering its callback. The capture must reach recovery within a fixed bound.

### F05 — P1: External-display sessions incorrectly require an iPad send

**Location:** [Mac/UI/BoothCoordinator.swift:982–984](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:982), `1808–1820`, `2996–3008`.

An active external viewer satisfies `isCustomerDisplayReady`, but both new and recovered sessions start their countdown only after `.sessionPrepared` reports `.sent` to the iPad transport.

**Trigger and impact:** Run the supported external viewer without an iPad. The session is created and reaches Ready, but countdown never starts. A failed setup send to a real iPad can leave the same state; reconnect synchronization does not rerun this countdown callback.

**Smallest correction:** Start the authoritative local countdown when the external viewer is the active customer display. For iPad setup failure, retain an explicit retryable setup operation that reconnect can complete.

**Required check:** Complete a session using only the external viewer, and recover from a failed iPad setup send without cancelling the guest's session.

### F06 — P1: Next Session and Reset to Idle do nothing after completion

**Location:** [Mac/UI/BoothCoordinator.swift:2592–2595](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:2592), `3348`; [Mac/UI/ExternalDisplayView.swift:374–376](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/ExternalDisplayView.swift:374); [Mac/UI/OperatorConsoleView.swift:645–650](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/OperatorConsoleView.swift:645).

Completion sets `currentSession = nil` while waiting for the customer acknowledgement. Both the external viewer's Next Session button and the operator's Reset to Idle button dispatch `.cancelSession`, whose guard rejects a nil `currentSession`.

**Trigger and impact:** Finish a session, then use either Mac-side button. The booth remains at Finished. If the iPad is absent or unavailable, the operator has no working reset through these controls.

**Smallest correction:** Handle completed-session acknowledgement separately from destructive cancellation, and clear `finishedAwaitingCustomerAckSessionID` and the related display state. Removing only the guard is insufficient: the nil-session cancellation branch also does not clear that acknowledgement flag.

**Required check:** Finish a session, invoke each Mac-side reset path, and successfully start the next guest session while preserving completed files.

### F07 — P1: A temporary review save failure becomes permanently cached

**Location:** [Mac/UI/BoothCoordinator.swift:2682–2716](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:2682); [iPad/UI/iPadViewModel.swift:553–555](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/iPad/UI/iPadViewModel.swift:553), `1579–1590`.

The Mac caches `.persistenceFailed` in `recentReviewRequests`. The iPad deliberately retries with the same request ID. Every retry therefore returns the cached failure without attempting the save again, even after storage recovers. The capture-recovery cache already excludes this transient result, but the review cache does not.

**Trigger and impact:** A Keep or Retake manifest write fails once. The advertised safe retry cannot succeed, leaving the guest stuck until an additional operator/reconnect intervention changes the state.

**Smallest correction:** Do not cache transient persistence failures as terminal review decisions. Preserve deduplication for actions that committed.

**Required check:** Fail the first save, restore storage, and retry the identical request ID. It must commit once and then deduplicate further retries.

### F08 — P1: Finalization enqueue failure leaves the UI and manifest in incompatible states

**Location:** [Mac/UI/BoothCoordinator.swift:2655–2660](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:2655), `3045–3085`, `3090–3093`.

Finalization durably changes the manifest from Capturing to Finalizing before enqueueing its jobs. If queue persistence fails, `finalizeSession()` returns false and `acceptShot()` leaves the UI in Review. Another Keep attempts a write allowed only in Capturing. The reconciliation path runs only while the UI is Processing.

**Trigger and impact:** Queue storage fails after the last photo's manifest transition, including during optional cloud/print enqueue. Repairing storage alone does not restore a usable review or processing path; the session can remain stuck until restart/recovery or cancellation.

**Smallest correction:** Reconcile a durable Finalizing manifest into an explicit retryable finalization state and retry the missing queue writes. Do not retry the already-committed capture operation.

**Required check:** Inject queue persistence failure after the Finalizing transition, recover storage, and complete the same session without recapture or restart.

### F09 — P1: Retrying a required job does not recover its failed manifest

**Location:** [Mac/UI/BoothCoordinator.swift:3214–3224](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:3214), `3268–3276`; [Mac/Jobs/JobQueueStore.swift:218–233](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/JobQueueStore.swift:218); [Mac/Jobs/SessionJobExecutor.swift:128–147](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/SessionJobExecutor.swift:128).

A permanent required-job failure changes the session manifest to Failed. Operator Retry resets only the job. Retried strip rendering still requires a Finalizing manifest, and completion likewise permits only Finalizing to Completed. Recovery scanning does not restore Failed sessions to Finalizing.

**Trigger and impact:** A required render/download job fails, then its underlying problem is corrected. Retry either fails again on the manifest status or cannot finish the guest session.

**Smallest correction:** Make the authorized required-job retry restore the durable session state to Finalizing, with the existing cancellation checks, before making the job runnable.

**Required check:** Permanently fail a required job, correct the cause, retry through the operator path, and reach Completed.

### F10 — P1: Successful queue storage recovery leaves workers stopped

**Location:** [Mac/Jobs/SessionJobQueue.swift:100–109](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/SessionJobQueue.swift:100), `288–303`.

Startup storage failure sets `isRunning = false`. `retryPersistenceRecovery()` subsequently restarts workers only if they were running before recovery. The exact startup-failure case therefore reports successful recovery but never starts the workers.

**Trigger and impact:** Queue loading fails at app startup, then the operator repairs storage and uses Retry Storage Recovery. Queued rendering, upload, and printing remain idle until app restart.

**Smallest correction:** Track intended worker operation separately from the failed running state, or explicitly restart after the operator's successful recovery action.

**Required check:** Fail startup queue loading, repair it, invoke the real recovery action, and observe a queued job execute without restarting the app.

### F11 — P1: Cloud command timeout can wait indefinitely for descendant pipes

**Location:** [Mac/Cloud/CloudUploadService.swift:97–108](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Cloud/CloudUploadService.swift:97), `126`, `141–170`, `261–284`.

The runner waits for stdout/stderr readers before completing. Its post-launch `setpgid` can fail after exec, leaving only parent-PID termination. If the parent exits and a descendant retains a pipe, timeout/cancellation neither terminates that descendant nor releases the readers.

**Trigger and impact:** An SSH proxy or helper survives its parent and holds stdout/stderr open. The configured timeout stops bounding the command; the single cloud worker can remain occupied indefinitely and cancellation cannot establish quiescence.

**Smallest correction:** Establish process-group ownership at spawn time, and ensure deadline handling bounds pipe draining even after the parent exits. Do not report successful termination while owned descendants remain alive.

**Required check:** Let the parent exit before the timeout, leave a descendant holding stdout, and assert bounded return and descendant cleanup. This differs from cancelling while the parent is still alive.

**Runtime evidence:** The current `CloudUploadService.swift` was compiled unchanged with minimal dependency stubs in [/tmp/prc_process_probe_main.swift](/tmp/prc_process_probe_main.swift). A shell that starts `sleep 3`, waits 0.1 seconds, and exits leaves the child holding its pipes. With a configured 0.3-second timeout, the runner returned its timeout error after **3.017 seconds**. This confirms the timeout defect without an external SSH server. Probe command: `swiftc Mac/Cloud/CloudUploadService.swift /tmp/prc_process_probe_main.swift -o /tmp/prc_process_probe && /tmp/prc_process_probe`.

### F12 — P1: Session synchronization can strand missing iPad assets

**Location:** [iPad/UI/iPadViewModel.swift:702–708](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/iPad/UI/iPadViewModel.swift:702), `789–808`, `1092–1093`; [Shared/Connectivity/BoothTransport.swift:797–819](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Shared/Connectivity/BoothTransport.swift:797).

An accepted same-session snapshot resets the asset assembler and cancels all response deadlines, but retains `assetRequestPump.inFlight`. References retained by the snapshot remain in flight, so the next request batch excludes them and no new deadline is armed.

**Trigger and impact:** A sync arrives while a requested asset is missing or its completion belongs to the discarded processing generation. The review, prompt, or strip image can remain missing with no retry, channel recycle, or timeout escalation.

**Smallest correction:** Clear/reconcile the in-flight request set whenever processing is reset, then re-request the snapshot's missing assets and arm their deadlines.

**Required check:** Request asset A, receive a same-session snapshot still referencing A before completion, and verify that A is requested again with a live deadline.

### F13 — P1: Legacy retention cleanup bypasses the active-job safety barrier

**Location:** [Mac/UI/BoothCoordinator.swift:3442–3455](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:3442), `3491–3503`.

The manifest cleanup loop correctly retains an old completed session when its work cannot quiesce. The following legacy loop selects all old SwiftData sessions, including that same runtime-backed session, and deletes its output directory without checking its manifest or job barrier.

**Trigger and impact:** At startup, a session older than 60 days still has non-quiesced work. Its files and SwiftData record can be deleted despite the earlier explicit cleanup-pending decision. This is a maintenance-triggered data-safety issue, not a normal first-day session failure.

**Smallest correction:** Restrict the legacy path to sessions demonstrably predating runtime manifests. Treat an unreadable manifest as a reason to retain files rather than permission to delete them.

**Required check:** Keep an old runtime-backed session's worker active through cleanup and verify that both files and its record survive the legacy pass.

### F14 — P2: Seven-day job pruning breaks retained cloud retries

**Location:** [Mac/UI/BoothCoordinator.swift:3489](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:3489); [Mac/Jobs/JobQueueStore.swift:378–382](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/JobQueueStore.swift:378); [Mac/Jobs/SessionJobQueue.swift:510–513](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/SessionJobQueue.swift:510).

Succeeded jobs are deleted after seven days while sessions are retained for 60 days. A failed cloud job survives, but its succeeded `renderStrip` dependency can be removed. Requeue changes the cloud job to Pending; the scheduler will never run it without that dependency row.

**Trigger and impact:** Retry an older failed upload after startup pruning. The UI accepts the retry but the upload remains pending indefinitely.

**Smallest correction:** Retain dependency records while a session has retryable work, or explicitly validate the durable completed output when restoring a retry dependency.

**Required check:** Age a succeeded strip job and failed cloud job beyond seven days, prune, retry, and verify that upload runs.

### F15 — P2: Gallery GIF links remain missing after successful GIF generation

**Location:** [Mac/Jobs/SessionJobQueue.swift:119–124](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/SessionJobQueue.swift:119); [Mac/Jobs/SessionJobExecutor.swift:172–195](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Jobs/SessionJobExecutor.swift:172), `257–270`; [Mac/UI/BoothCoordinator.swift:3376](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:3376).

The finalization lane runs gallery update before GIF rendering. The gallery stores the then-nil `gifFileName`. GIF completion updates the manifest and SwiftData paths but never refreshes the gallery entry. Gallery routes derive availability from the stale gallery entry.

**Trigger and impact:** A normal session generates a GIF with gallery GIF links enabled. The session GIF exists, but the event gallery never offers its GIF link.

**Smallest correction:** Refresh only the gallery's output metadata after GIF completion, preserving its moderation decision and keeping optional gallery work outside the customer completion gate.

**Required check:** Execute the production job order and confirm the approved gallery entry exposes the GIF after rendering succeeds.

### F16 — P2: Local selection validation failure leaves the start latch set

**Location:** [Mac/UI/BoothCoordinator.swift:1589–1593](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:1589), `1644–1655`.

The validation catch releases `activeSessionStart` only when a wire request ID exists. Operator and external-viewer starts have no request ID. A stale or invalid local selection therefore retains the start latch despite creating no current session.

**Trigger and impact:** Change event options after an external selection was prepared, then press Start. The validation error appears, but every subsequent start returns early as already starting. The operator cancellation guard also refuses this state because no current session exists.

**Smallest correction:** Release the start latch on every validation failure; only the wire response should depend on `respondsToRequest`.

**Required check:** Fail a local start with a stale revision, refresh the selection, and successfully start without app restart.

## Deployment privacy boundary

Local guest downloads and galleries use plaintext HTTP ([Mac/Server/LocalWebServer.swift:120–142](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/Server/LocalWebServer.swift:120); [Mac/UI/BoothCoordinator.swift:3297–3310](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/Mac/UI/BoothCoordinator.swift:3297)). The bearer token is part of `/s/<token>/`. An attacker able to observe or alter the guest's network traffic can obtain the token and media, replay the URL, or modify the response. Ordinary membership in a WPA network does not by itself prove that capability.

This is a documented trusted-network design ([README.md:241](/Users/nont/My-Project/PRC-PhotoBooth-v1.4/README.md:241)), not an additional authentication bypass. It remains a material privacy limitation on an untrusted venue network. Use an operator-controlled isolated network or properly configured HTTPS delivery. Product-level encrypted local delivery requires trusted HTTPS termination. Remote Operator is separately disabled in Release builds; that protection does not encrypt guest media.

## Validation and remaining acceptance gates

- Current source syntax parsing passed for Mac + Shared and iPad + Shared with `xcrun swiftc -frontend -parse`.
- `git diff --check` passed before this report was added.
- Fresh Mac test run passed: **449 test executions, 0 failed, 0 skipped**. Swift Testing's top-level count is 446 tests in 60 suites because one test has dynamic parameters. Command: `xcodebuild -project PRC-PhotoBooth.xcodeproj -scheme PRC-PhotoBoothTests -destination 'platform=macOS' -derivedDataPath /tmp/prc-event-audit-20260922-mac test`. Result bundle: `/tmp/prc-event-audit-20260922-mac/Logs/Test/Test-PRC-PhotoBoothTests-2026.09.22_22-03-34-+0700.xcresult`. This also built the Mac app and test bundle.
- Fresh iPad simulator test run is in progress; the final result will be recorded here.
- Fresh physical camera, printer, and iPad tests, an adversarial network test, and a sustained event soak were not performed by this audit.
- The prior release ledger records 449 Mac tests, 23 iPad tests, builds, and a Mac TSan run passing on the final code. Those are prior results, not reruns performed by this audit.
- Production connection replacement still crosses MainActor. The existing ledger explicitly leaves the blocked-MainActor production reconnect gate unverified. It is an acceptance gap here, not an independently reproduced outage.
- Session completion and job-change callbacks repeatedly load historical manifests and rebuild routes. Accepted-capture file writes also run synchronously from the MainActor coordinator. Their impact under accumulated event history needs measured latency, memory, thermal, and 100-session profiling; this audit does not invent a throughput limit.

The fresh checks above cannot prove away the listed failure paths. Add focused production-path regressions while fixing each defect, then run the physical camera/printer/network matrix and a sustained event workload before changing the verdict.
