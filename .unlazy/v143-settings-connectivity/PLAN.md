# Plan: v1.4.3 settings and iPad connectivity remediation

Scope: v143-settings-connectivity
Depth: tree 3
Mode: orchestrated

## Contract

- Interfaces: preserve the existing framed Message protocol and stored-secret pairing contract. Do not change wire acceptance until the first malformed inbound control frame is identified. Any protocol fix must maintain authenticated encryption after secure establishment, monotonic counters, fresh reconnect sessions, and generation checks.
- Ownership: protocol work owns the secure-channel, decoder, runtime, and associated network test files; Settings work owns MacApp and MacContentView plus focused existing tests; iPad presentation work owns connection presentation, iPad connection settings, view model, and focused iPad tests. Existing local edits to localization catalogs, project.pbxproj, shared scheme, and Xcode UI state are excluded.
- Dependencies: Settings and iPad presentation implementation wait for the protocol leaf to pass its gate. Three read-only audits can run independently before implementation.
- Host launch mode: Codex native subagents.
- Wave policy: launch the three read-only audits together, then implement protocol work first. No concurrent implementation leaves may edit Shared/Connectivity.
- Toolchain: Xcode 26.6.0 at /Applications/Xcode-26.6.0.app/Contents/Developer, macOS 15+ target, iPadOS 16+ target, zsh working directory at repository root.
- Conventions: Swift 6, 4-space indentation, typed symbolic diagnostics, no secrets or plaintext application payloads in logs, no timeout-only or plaintext-fallback workaround.
- Manual review: root reviews audit reports and final security review. Physical validation requires the named iPad Pro 9.7-inch on iPadOS 16.7.16 and the production Mac.

## Current contract inventory

Contract revision: 1

| ID | Required outcome or constraint | Owner | Observation | Disposition | Revision |
|---|---|---|---|---|---|
| C1 | Identify the exact first invalid control frame and protocol phase before changing acceptance rules. | leaf-2.1 + node-3 | leaf-2.1 G1, node-3 N2 | ACTIVE | 1 |
| C2 | Add safe diagnostics with timestamp, role, connection/route generations, sanitized endpoint, security phase, byte count, envelope markers, decoded Message case name, and symbolic error; never log secrets or payloads. | leaf-2.1 | leaf-2.1 G2 | VERIFIED | 1 |
| C3 | Preserve strict pre-auth, negotiation, and post-establishment encryption rules; process coalesced frames sequentially across state changes. | leaf-2.1 + node-3 | leaf-2.1 G3, node-3 N1 | VERIFIED | 1 |
| C4 | Exercise the production-equivalent control path through trusted auth, secure bootstrap, and encrypted operational traffic across at least 100 reconnect cycles. | leaf-2.1 + node-3 | leaf-2.1 G4, node-3 N1 | VERIFIED | 1 |
| C5 | Replace eight-category segmented Settings navigation with a native adaptive sidebar/detail layout; preserve all settings and PIN behavior. | leaf-2.2 | leaf-2.2 G1-G2 | ACTIVE | 1 |
| C6 | Keep the preferred Mac identity and reconnect presentation stable during temporary discovery loss while reporting connection truthfully. | leaf-2.3 | leaf-2.3 G1-G2 | VERIFIED | 1 |
| C7 | Validate relevant Mac and iPad build/test gates using Xcode 26.6.0. | node-3 | node-3 N3 | VERIFIED | 1 |
| C8 | Run an independent final security and over-engineering review. | node-3 | node-3 N4 | VERIFIED | 1 |
| C9 | Run physical Wi-Fi, hotspot, restart, foreground recovery, and soak checks on the named hardware when available. | operator/root | node-3 N5 manual | ACTIVE | 1 |

## State vocabulary

Leaves use WAITING, READY, IN-FLIGHT, VERIFIED, or ABANDONED. Branches use OPEN, VERIFIED, or ABANDONED. Physical outcomes stay pending until observed on hardware.

## Tree

- 1 v1.4.3 settings and connectivity remediation ... GATES.md
  - 1.1 Independent investigation ................ gates/node-1.1.md
    - 1.1.1 Control protocol forensic audit ....... gates/leaf-1.1.1.md
    - 1.1.2 macOS Settings audit .................. gates/leaf-1.1.2.md
    - 1.1.3 iPad reconnect presentation audit ..... gates/leaf-1.1.3.md
  - 2 Implementation .............................. gates/node-2.md
    - 2.1 Secure control remediation .............. gates/leaf-2.1.md
    - 2.2 macOS Settings redesign ................. gates/leaf-2.2.md
    - 2.3 iPad reconnect presentation ............. gates/leaf-2.3.md
  - 3 Integrated release verification ............. gates/node-3.md

## Leaf dispatch table

| Leaf | Owns | Needs | Tier | Planned wave | State |
|---|---|---|---|---:|---|
| 1.1.1 | .unlazy/v143-settings-connectivity/reviews/protocol.md | - | judgment | 1 | READY |
| 1.1.2 | .unlazy/v143-settings-connectivity/reviews/settings.md | - | judgment | 1 | READY |
| 1.1.3 | .unlazy/v143-settings-connectivity/reviews/ipad.md | - | judgment | 1 | READY |
| 2.1 | Shared/Connectivity/BoothPairing.swift, Shared/Connectivity/BoothTransport.swift, Shared/Connectivity/BoothSecureChannelNegotiator.swift, Shared/Connectivity/BoothControlWritePump.swift, Shared/Connectivity/BoothNetworkTransportRuntime.swift, Shared/Connectivity/NetworkBoothTransport.swift, Shared/Connectivity/Message.swift, Tests/NetworkFramingTests.swift, Tests/BoothPairingTests.swift, Tests/NetworkRouteTests.swift | 1.1.1 | judgment | 2 | IN-FLIGHT (G1 incident trace pending) |
| 2.2 | Mac/MacApp.swift, Mac/UI/MacContentView.swift, Tests/LocalizationTests.swift | 1.1.2, 2.1 | judgment | 3 | IN-FLIGHT (rendered Settings review pending) |
| 2.3 | Shared/Connectivity/BoothConnectionPresentation.swift, iPad/UI/iPadViewModel.swift, iPad/UI/iPadConnectionSettingsView.swift, Tests/BoothConnectionPresentationTests.swift, iPadTests/iPadSmokeTests.swift | 1.1.3, 2.1 | judgment | 3 | IN-FLIGHT (physical 9.7-inch validation pending) |
