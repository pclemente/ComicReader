# ComicReader 1.6.1 reliability validation

Focused validation on 26 October 2026 revisited older public reports about
library imports, collections, duplicate handling, saved reading position and
the Files picker. This was a verification pass: no production-code change was
needed. Two existing regression checks were strengthened to cover a repeated
library scan and a full app relaunch.

## Environment

- Xcode 27.1 (27A9275) on macOS 27.0.1.
- iPad Pro 13-inch (M5) simulator, arm64, iPadOS 27.0 (24A434).
- Candidate production source at `f33b58c97da6551da75569c4c4abb1b44101e069`;
  the additional changes exercised here are test-only.

## Results

- `ComicReader-1.6.1-reliability-units-ios27-v2.xcresult`: 5 passed, 0 failed,
  0 skipped.
- `ComicReader-1.6.1-reliability-ui-ios27.xcresult`: 2 passed, 0 failed,
  0 skipped.

The focused checks confirm that:

- importing a comic preserves the source file, reuses an exact duplicate and
  does not reset the existing reading position;
- duplicate content is reused, while same-name content never overwrites an
  existing comic;
- direct visible library folders remain real folders rather than symlinks;
- an indexed comic stays in its direct collection, keeps its collection
  membership and restores exact page 2 after repeated launch-equivalent scans;
- a file imported from a hidden or deeper unindexed location is copied safely
  to the library root and indexed once;
- a UI-imported PDF stays visible after termination and relaunch, reopens
  successfully and restores exact page 2 after portrait/landscape transitions;
- with the web server disabled, Settings opens the system Files picker, the
  picker can be cancelled, and Settings remains usable after rotation.

Two earlier result bundles are not test results: the iPadOS 26.2 attempt and a
stale `test-without-building` attempt each executed zero tests and were
discarded. The successful bundles above are the evidence for this pass.

## Scope limits

ComicReader treats only direct, visible folders under the library root as
collections. It does not present arbitrary multi-level folders as nested
collections. Files selected from deeper or hidden locations are copied to the
library root instead; this pass verifies that safe fallback and does not claim
nested-collection support.

This was focused simulator validation, not a complete regression run or a
physical-device, live-iCloud or third-party Files-provider test. It confirms
the current import and persistence behavior; it cannot recover files that were
already removed before this version.
