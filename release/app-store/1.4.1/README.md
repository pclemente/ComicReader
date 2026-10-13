# ComicReader 1.4.1 (12)

Both iPhone/iPad and Mac updates are **Waiting for Review**, submitted on
13 October 2026 with automatic release after approval. See
[submission-record.json](submission-record.json) and
[the App Store Connect overview](submission-evidence/review-overview.png).

Version 1.4 (11) had already been released, so its screenshots were locked.
This update changes only the production version/build and replaces the store
galleries. It does not change app behavior, Plus pricing or free iCloud sync.

## Screenshot galleries

Each gallery contains five images in this order: library, reader, comic text
search, reading lists and free iCloud sync. All use genuine application screens
and approved public-domain demo comics; the comics are not bundled with the app
or included in Plus.

| Platform | Size | Final images | Preview |
| --- | --- | --- | --- |
| iPhone | 1206 × 2622 | [Five PNGs](screenshots/en-GB/iphone) | [Contact sheet](design-preview/iphone-final-contact-sheet.png) |
| iPad | 2064 × 2752 | [Five PNGs](screenshots/en-GB/ipad) | [Contact sheet](design-preview/ipad-final-contact-sheet.png) |
| Mac | 2880 × 1800 | [Five PNGs](screenshots/en-GB/macos) | [Contact sheet](design-preview/macos-final-contact-sheet.png) |

All 15 images are opaque RGB PNGs. Each App Store Connect gallery and its
inheritance to other device sizes was verified. Source captures, hashes,
composition records and visual QA reports are retained here. Mac originals
include the recorded OS titlebar or empty-padding crops; no app content or
controls were retouched.

## Validation

- iPhone and iPad screenshot journeys passed using 1.4.1 (12), genuine imports,
  reading lists, OCR search and local StoreKitTest purchases through the app UI.
- Mac screenshots use the actual Debug 1.4 (11) interface, whose production
  source is identical to the version-only update. An in-memory Plus fixture
  enabled capture; it was not a production purchase test. Real OCR indexed the
  sample comic and returned the displayed result.
- Both production packages were uploaded and processed. Versions, signatures,
  production iCloud entitlements, architectures, matching dSYMs and absence of
  test fixtures were checked. Mac installer signing and sandboxing were checked.
- The capture helper's syntax, argument handling, historical-path protection
  and overwrite protection passed static checks. Capture tests require an
  explicit fixture marker and otherwise skip before interacting with the app.

This screenshot release does not revalidate live cross-device iCloud sync,
production purchase propagation, the full regression suite or minimum OS
runtimes. iCloud remained off during captures.

## Reproduction and history

`Tests/capture-app-store-screenshots.py --help` documents fresh iOS capture runs.
Use a new output directory for retakes. `compose_screenshots.py` generates the
store graphics from the approved inputs; `screenshot-plan.json` records the
roles and requirements. Visually review any future output before uploading it.

[upload-record.json](upload-record.json) identifies the signed artifacts and
external archive paths. Binaries and demo libraries remain outside this release
directory. [historical-artifacts.json](historical-artifacts.json) records the
byte-for-byte preservation of the previous 1.4 screenshot evidence.
