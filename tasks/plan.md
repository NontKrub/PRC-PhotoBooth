# Implementation Plan: PRC PhotoBooth 1.2 Guest Experience

## Goal

Add JSON-backed event experiences, guest template/filter/language selection, pose prompts, local moderated galleries, and hardware-free Debug testing while preserving V1.1 manifests, accepted originals, queue semantics, and legacy messages.

## Ordered slices

1. Shared contracts: localized text, languages, filters, templates, catalogs, selections, presentations, and backward-compatible `EventConfig`.
2. Core Image filters: one reusable pipeline, deterministic samples, tolerant tests.
3. Experience storage: atomic JSON packages, legacy migration, validation, asset imports, previews, and legacy mirror.
4. Selection transport: catalog/assets, stale-selection validation, `selectingExperience`, iPad flow, and external-display draft flow.
5. Session integration: selected config, presentation snapshot, filtered review/strip/GIF, and recovery.
6. Gallery: index store, thumbnails, optional queue job, local routes, localized pages, and moderation.
7. Operator/customer polish: template editor, prompts, language settings/catalog localization, demo camera/seeding/kiosk, docs, and version 1.2 build 3.

## Verification gates

- Run focused Swift Testing after each slice, then full Mac tests and Mac/iPad builds.
- Preserve pre-existing dirty generated/user-state files; stage only intentional source/config/docs changes.
- Run Debug demo apps through Computer Use after automated checks; capture screenshots and record defects.
- Review diff for data-loss, path traversal, HTML escaping, unsupported filters, audio additions, and SwiftData schema changes before PR.

## Known simplifications

- Use existing SwiftUI/AppKit controls and synthetic Core Graphics samples; no new dependencies.
- Keep the existing frame-slot editor behavior while adapting its data boundary incrementally.
- Keep gallery local-only and optional; individual session downloads remain authoritative.
