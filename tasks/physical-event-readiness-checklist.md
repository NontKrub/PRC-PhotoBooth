# PRC PhotoBooth v1.4.3 — Physical Event Readiness & Deployment Checklist

This document is the operational checklist for booth operators deploying PRC PhotoBooth at live events.

---

## 1. Hardware & Physical Setup

### A. Mac Operator Station
- [ ] Connect Mac to reliable AC power (Magsafe/USB-C charger).
- [ ] Connect Sony ZV-E10 via high-speed USB-C cable directly to Mac (avoid unpowered USB hubs).
- [ ] Connect Canon CP1500 printer via USB cable or ensure Wi-Fi direct connection.
- [ ] Load fresh paper cassette (Postcard 4x6 / Strip) and new ink ribbon into Canon CP1500.
- [ ] Connect Ethernet cable from venue router/switch or join dedicated event Wi-Fi network.

### B. Customer iPad
- [ ] Mount iPad securely in enclosure.
- [ ] Connect iPad to continuous USB power.
- [ ] Join same Wi-Fi network or verify direct Ethernet adapter connection.
- [ ] Launch `PRC PhotoBooth` on iPad.

### C. External Customer Display (if equipped)
- [ ] Connect HDMI / USB-C to external display.
- [ ] Set display arrangement to Extended Display (not Mirroring) in macOS System Settings.
- [ ] Launch external display window in PRC PhotoBooth (`Window -> Customer Display`).

---

## 2. Network & Guest Delivery Preflight

- [ ] Open **PRC PhotoBooth -> Settings -> iPad & Network**:
  - Verify iPad is paired and connected.
  - Verify route indicator shows `Wired Ethernet` or `Wi-Fi LAN` (not fallback/disconnected).
- [ ] Verify **Local Guest Delivery Route**:
  - Ensure the IP address displayed under `Sharing Station URL` is an RFC 1918 LAN IP (e.g. `192.168.x.x` or `10.x.x.x`).
  - **INVARIANT**: The QR code must NEVER show `localhost` or `127.0.0.1`. If "Local delivery unavailable" appears, check Ethernet/Wi-Fi connection.
- [ ] Scan sample QR code with a mobile phone to confirm phone reaches the download page.

---

## 3. Automated Event Readiness Soak Test (Mandatory Before Guest Opening)

Run the automated soak test from the operator Mac before admitting attendees.

1. Open **Settings -> Event Readiness**:
2. **Preflight Diagnostics**:
   - Verify green checkmark: "All preflight checks passed."
   - Confirm disk space has at least 3.0 GB free.
3. **Run Camera-Only Smoke Test**:
   - Select Mode: `Camera-Only`.
   - Select Target Cycles: `25 (Short Benchmark)` or `50 (Standard Soak)`.
   - Ensure "Enable Physical Printing" is **OFF**.
   - Click **Start Soak Test** and confirm.
   - Watch live progress: verify consistent capture latency (~0.3s–0.8s) and 0 errors.
4. **Run Full-Pipeline Stress Test**:
   - Select Mode: `Full Pipeline`.
   - Select Target Cycles: `50 (Standard Soak)` (or `100` for multi-hour events).
   - Ensure "Auto-cleanup test session files" is **ON**.
   - Click **Start Soak Test** and confirm.
   - Verify all phases (capture, compositing, job queue processing, local delivery) complete with 0 failures.
5. **Inspect & Export Report**:
   - Review the final report card.
   - Click **Export Report…** and save report to the event documentation folder.

---

## 4. Canon CP1500 Print Safety Rules

- [ ] **Physical Print Invariant**: The booth enforces strict duplicate prevention. If macOS AppKit reports a print timeout or unknown outcome, DO NOT blindly click "Retry Print" without first checking the printer output tray.
- [ ] Inspect the printer paper feed:
  - If paper is jammed or empty, clear jam or insert paper.
  - Check the operator console for print job status (`succeeded`, `failed`, or `sideEffectUnknown`).
  - Only use manual operator reprint after confirming the physical photo was not printed.

---

## 5. Live Event Recovery Procedures

### Camera Disconnects or Freezes
- If the Sony ZV-E10 loses USB connection:
  1. Reconnect the USB-C cable.
  2. The Mac app will automatically detect and re-bind the camera.
  3. If a capture attempt was in progress, the booth will attempt authenticated recovery.
  4. **INVARIANT**: If the camera produced no new photo for the current session, the attempt will fail cleanly and prompt for retake. It will NEVER substitute an older guest's photo.

### iPad Disconnects
- If iPad battery dies, app is backgrounded, or Wi-Fi drops:
  - The Mac preserves the active session state.
  - When the iPad reconnects, cryptographic reconnect tokens automatically re-authenticate the session without requiring PIN re-entry.
  - The customer display state machine immediately resynchronizes to the active session phase.

### Power Loss / App Crash Recovery
- If the Mac reboots unexpectedly:
  1. Launch PRC PhotoBooth.
  2. The startup reconciliation service automatically inspects persisted manifests and the job queue.
  3. Any session in `.finalizing` will resume missing render or upload jobs with its matching `finalizationTransactionID`.
  4. Interrupted jobs are safely reconciled without duplicate printing.
