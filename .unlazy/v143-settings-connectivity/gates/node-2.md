# Gates: implementation integration

Scope: integrate the protocol fix, Settings layout, and iPad reconnect presentation.

- [ ] N1: each implementation child passes parent re-verification
  EVIDENCE: Protocol loopback/framing work and iPad presentation behavior pass automated gates. Settings click-through and rendered size/localization checks remain open; see child ledgers.

- [x] N2: connection state stays truthful across socket failure and generation replacement
  EVIDENCE: Presentation policy requires the current preferred peer plus authenticated secure transport before showing Connected; route tests verify fresh generation/session reconnect behavior.

- [x] N3: security and presentation behaviors compose without settings or iPad regressions
  EVIDENCE: Full Mac test suite and iPad simulator suite pass; Mac and iPad Debug/Release builds pass. Visual Settings/9.7-inch acceptance is separately open.
