# Gates: iPad reconnect presentation

OWNS: Shared/Connectivity/BoothConnectionPresentation.swift, iPad/UI/iPadViewModel.swift, iPad/UI/iPadConnectionSettingsView.swift, iPad/Localizable.xcstrings, Tests/BoothConnectionPresentationTests.swift, iPadTests/iPadSmokeTests.swift

Scope: keep the preferred Mac row and friendly reconnect status stable through short discovery gaps while reflecting authenticated transport truth.

- [x] G1: presentation tests prove preferred name retention, no UUID substitution, and stable reconnect state through temporary discovery loss
  EVIDENCE: `BoothConnectionPresentationTests` passed in the final Mac suite and cover preferred identity/name retention, UUID suppression, nearby-row expiry, and truthful authenticated/secure connected state. iPad smoke suite passed 23/23 on the available 13-inch simulator.

- [ ] G2: iPad screen remains readable on iPad Pro 9.7-inch width and technical errors remain in operator diagnostics
  EVIDENCE: Technical failures are kept in sanitized diagnostics and user-facing connection text is generic/localized. The 9.7-inch iPadOS 16.7.16 layout and physical reconnect recording remain unverified because that device is unavailable.
