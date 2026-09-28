# Gates: macOS Settings redesign

OWNS: Mac/MacApp.swift, Mac/UI/MacContentView.swift, Mac/Localizable.xcstrings, Tests/LocalizationTests.swift

Scope: replace segmented Settings navigation with a native responsive sidebar and top-aligned vertical detail pane.

- [x] G1: all eight categories select a valid detail view and the PIN flow and existing setting behavior remain intact
  EVIDENCE: The eight stable navigation IDs resolve to the existing section routes, including Event Readiness; the new Settings scene builds on Xcode 26.6 and the localization route/catalog tests pass. The existing protected Settings/PIN wrapper remains in place. Interactive PIN lock/unlock was not exercised.

- [ ] G2: built Settings scene fits minimum and enlarged sizes without clipped content or excessive blank space in English and Thai
  EVIDENCE: Source layout review and Impeccable detector passed (`[]`), but no rendered Settings screenshots or interactive resize/Thai geometry checks were captured at the requested sizes. Keep this gate open.
