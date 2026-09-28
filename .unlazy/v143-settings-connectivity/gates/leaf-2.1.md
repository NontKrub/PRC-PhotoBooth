# Gates: secure control remediation

OWNS: Shared/Connectivity/BoothPairing.swift, Shared/Connectivity/BoothTransport.swift, Shared/Connectivity/BoothSecureChannelNegotiator.swift, Shared/Connectivity/BoothControlWritePump.swift, Shared/Connectivity/BoothNetworkTransportRuntime.swift, Shared/Connectivity/NetworkBoothTransport.swift, Shared/Connectivity/Message.swift, Tests/NetworkFramingTests.swift, Tests/BoothPairingTests.swift, Tests/NetworkRouteTests.swift

Scope: identify and correct the proven malformed-envelope cause while enforcing sequential, generation-bound secure control processing.

- [ ] G1: first invalid inbound control frame and incorrect receiving phase are reproduced and named before acceptance changes
  EVIDENCE: The incident frame is not present in the supplied text or local incident artifacts. Diagnostics now record timestamp, role, generations, sanitized endpoint, frame/envelope metadata, plaintext Message case name, auth/secure phase, and symbolic error. Do not call the production `malformedEnvelope` incident root-caused until a device trace is captured.

- [x] G2: safe symbolic failure diagnostics expose frame metadata without secrets or application payload
  EVIDENCE: `BoothControlFrameDecodeFailure` and transport events carry only symbolic names, counts, envelope markers/version/channel, phase flags, and sanitized endpoint metadata. `NetworkFramingTests` verifies `malformedEnvelope` classification and that payload content is absent.

- [x] G3: coalesced and fragmented phase-crossing frames preserve strict encryption, authentication, replay, and generation rules
  EVIDENCE: Runtime/facade pull and handle control frames sequentially. Coalesced Ready→encrypted heartbeat, fragmented Ready→partially buffered encrypted heartbeat, and plaintext bootstrap after Ready tests pass. The full route suite verifies generation-bound operation and secure reconnects; the final Mac suite passes 672/672 with 13 existing skips.

- [x] G4: production-equivalent trusted loopback completes at least 100 fresh secure reconnect cycles with zero malformed envelopes
  EVIDENCE: `trustedRuntimeCompletesOneHundredSecureReconnectCycles` passed using real Mac/iPad runtimes, Network.framework loopback, `BoothControlWritePump`, stored secret, heartbeat, and encrypted application control. It asserts 100 unique matching session IDs, 100 controls/heartbeats, and zero decode failures/rejections.
