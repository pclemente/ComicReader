# App Store release preparation

Target app: ComicReader, bundle ID `com.pabloclementeperez.ComicFlow`.

## Current submission: 1.4.1 (12)

Version **1.4.1 (12)** was submitted on 13 October 2026 for iPhone/iPad and Mac.
Both are **Waiting for Review**, with automatic release after approval.
It replaces the store galleries with five current-interface screenshots per
platform: library, reader, comic text search, reading lists and free iCloud sync.
Version **1.4 (11)** is already **Ready for Distribution**; the new version was
needed to update its locked screenshots. Production behavior is unchanged.

See [1.4.1/README.md](1.4.1/README.md),
[submission record](1.4.1/submission-record.json), and
[App Store Connect proof](1.4.1/submission-evidence/review-overview.png).
The records below describe earlier releases as observed at their submission dates.

## Version 1.3 and earlier release history

Version **1.2 (4)** is **Ready for Distribution** as of 21 September 2026.
App Review rejected version **1.3 (7)** on 22 September 2026 under Guideline
4.10 because its submitted Plus benefits charged for iCloud functionality.
Submission
`487b805b-b3fe-42f3-90fe-036c2eaa703a` was sent on 21 September 2026 at 18:13
Europe/Madrid with iOS App 1.3 (7) and ComicReader Plus. The earlier build 6
submission `41f07f8d-ae7e-4d1b-84a8-8829d8019fcf` had been cancelled and
replaced. The rejected build 7 submission was cancelled on 22 September; the
app version and purchase returned to **Developer Rejected**, and build 7 was
removed from the app version.

Version **1.3 (9)** and ComicReader Plus were submitted on 22 September 2026 at
15:39 Europe/Madrid and both are **Waiting for Review**. Submission
`8528e3cf-59f0-467b-b703-34617ea29110` contains **2 Items Submitted**. Build 9 is
**Validated**, was uploaded by the CLI at 15:25:21 and appeared in App Store
Connect at 15:27 with UUID `82c48917-7a27-4a25-aca5-d9768c8d990f`. All app and
purchase metadata, the private purchase screenshot, TestFlight notes and five
existing iPad screenshots were saved and verified by clean reload. Manual release
remains selected.
Submission details:
https://appstoreconnect.apple.com/apps/1597314495/distribution/reviewsubmissions/details/8528e3cf-59f0-467b-b703-34617ea29110
Structured confirmation: `release/app-store/submission-build9.json`.
iCloud synchronization of comic files, read/unread status and current page is
free for everyone through a separate library-toolbar iCloud button. It remains
opt-in and uses the reader's personal iCloud storage.

Current-page text recognition, selection, copying and system sharing are also
free. The same €9.99 non-consumable Plus purchase now covers four app-specific
groups: Comic Search & Quotes, Custom Reading Lists, named Page Bookmarks and
renderer-only Clear Ink, Grayscale and Warm Paper Image Filters. Search indexes
the current comic and saved quotes retain their source page. Search indexes,
quotes, lists and bookmarks stay on this device. Filters never modify comic files,
and Original always restores normal rendering.
The dismissible **What's New** banner introduced in build 8 remains in build 9,
updates its message to include search and quotes, and offers **Free iCloud Sync**,
**Explore Plus** and an **X** close action without blocking saved-comic resume.

Manual release remains selected for the replacement. The owner requested the
five existing public store screenshots. The existing internal group has zero
testers and no invitations were sent. Live two-device free iCloud and purchase
propagation remain a validation limit, not an approval blocker. See
`docs/PlusUpgrade.md`, `docs/MonetizationReview.md` and `plus/what_to_test.txt`.

The final signed 1.3 (6) archive passed using `iphoneos27.0` with a 15.0 minimum
deployment target. Its signature and entitlements were verified.
Archive: `/tmp/ComicReader-1.3-build6-final.xcarchive`. The upload succeeded on
21 September at 11:18 Europe/Madrid and Apple processing is **Complete**. Build
ID: `3140bf50-a330-45b0-a028-6f2e7fab9fca`. Build 6 was attached to the cancelled
submission recorded above.

Archive log: `/tmp/ComicReader-archive-1.3-build6-final.log`.
Upload log: `/tmp/ComicReader-upload-1.3-build6.log`.

The signed 1.3 (7) archive passed at
`/tmp/ComicReader-1.3-build7-final.xcarchive`. Its upload succeeded on 21
September at 17:42 Europe/Madrid. App Store Connect records the binary as
**Validated**, uploaded at 17:43, with build ID
`f18ef6a5-f7c8-443f-a8f0-5ad3b09eaaa0`. This is the rejected build.

Build 7 archive log: `/tmp/ComicReader-archive-1.3-build7-final.log`.
Build 7 upload log: `/tmp/ComicReader-upload-1.3-build7.log`.

Rejected build 7 submission:
https://appstoreconnect.apple.com/apps/1597314495/distribution/reviewsubmissions/details/487b805b-b3fe-42f3-90fe-036c2eaa703a

Build 8 archive: `/tmp/ComicReader-1.3-build8-final.xcarchive`.
Archive log: `/tmp/ComicReader-archive-1.3-build8-final.log`.
Upload log: `/tmp/ComicReader-upload-1.3-build8.log`.
App Store Connect processing: **Complete**; build UUID
`623e6e7a-bf8c-423f-a1ba-97015edeacf1`.
Build 8 was not submitted and is superseded by the build 9 candidate.

Build 9 archive: `/tmp/ComicReader-1.3-build9-final.xcarchive`.
Archive log: `/tmp/ComicReader-archive-1.3-build9-final.log`.
The archive is version 1.3 (9), uses the iOS 27 SDK with an iOS 15.0 minimum,
and passed code-sign verification. The distribution export also passed deep
strict code-sign verification with `get-task-allow = false` and the Production
iCloud environment. Durable IPA:
`/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/ComicFlow.ipa`.
SHA-256: `df6909b10843c0d19db2f059bc970bd690bcd87ac6029b42428b957cb7e330f7`.
The upload attempt failed at 12:48:44 Europe/Madrid with unexpected HTML and a
504 gateway timeout while updating `CHECKSUM`; log:
`/tmp/ComicReader-upload-1.3-build9.log`. A fresh retry encountered another HTTP
504 at 13:07:21 while completing the asset description, then ended with exit 70
at 13:13:49 after repeated `CHECKSUM` and analysis-asset failures. No build 9
binary was uploaded. Durable failure logs are
`/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-failed.log` and
`/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-retry-failed.log`.
The third attempt succeeded at 15:25:21; durable log:
`/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-succeeded.log`.
App Store Connect marked build 9 **Validated**, displayed it at 15:27 and assigned
UUID `82c48917-7a27-4a25-aca5-d9768c8d990f`.

## Historical screenshot set (through version 1.3)

`compose_screenshots.py` prepares five bold comic-style marketing images from real, unmodified app captures. Apple accepts the selected iPad 13-inch slot at 2064 × 2752 pixels. The compositor emits opaque RGB PNGs at that size and refuses to run without full-resolution portrait captures.

1. **Your comics. Your collection.** — Populated library with varied cover art and reading-status ribbons.
2. **Let the story fill your screen.** — Full-screen comic page in the reader.
3. **Pick up where you left off.** — Resume an in-progress comic, with navigation controls visible.
4. **More ways to add your next read.** — The Files picker launched from Add Files.
5. **Your library, over Wi-Fi.** — Settings showing the web uploader or WebDAV address.

Use sample comics suitable for publication in the store listing. Capture the actual app and preserve its interface when composing each marketing image.

The five public screenshots are unchanged and were verified in App Store
Connect. `release/app-store/plus/review-screenshot.png` is now a fresh capture of
the actual build 9 Plus screen before purchase. It was uploaded and verified by
clean reload as asset `1af280f1-0852-4dca-ab26-b48bca576585`. The previously uploaded build 8 image is preserved at
`release/app-store/plus/review-screenshot-build8.png`; asset
`7225cae8-af92-405d-be78-4984cb767a59` remains build 8 evidence and omits Comic
Search & Quotes. The rejected build 7 screenshot remains at
`release/app-store/plus/review-screenshot-build7.png` for release history and
must not be reused because it associates sync with Plus.

`prepare_sample_library.py` creates nine sample CBZs with public-domain Winsor McCay art and original editorial covers. Sources are recorded in `sample-comics/sources.json`. Raw `page-03.jpg` is excluded from all fixtures and must not be used. The samples are release preparation material, not app-bundle content.

Capture these filenames into `captures/`, then run:

```sh
python3 release/app-store/compose_screenshots.py \
  --captures release/app-store/captures \
  --output release/app-store/screenshots/en-GB
```

For a future screenshot refresh, the required captures are `01-library.png`, `02-reader.png`, `03-progress.png`, `04-files.png`, and `05-transfers.png`. Visually inspect every output and the contact sheet before upload. The five current store screenshots are retained for version 1.3 at the owner's request.

## Prepared metadata

### Version 1.4 submission

Version 1.4 build 11 was submitted for iOS and Mac Catalyst on 11 October 2026.
Both platform submissions completed review and are **Ready for Distribution**
as of 13 October 2026. The original submitted metadata, screenshots and
submission-time records are preserved under `release/app-store/1.4/`.
The local app description, What's New and review notes now describe version 1.4;
they are not verbatim evidence of the version 1.3 build 9 submission below.
The immutable build 9 record remains `release/app-store/submission-build9.json`.

The build 8 English (U.K.) app metadata and review notes were saved and read back
in App Store Connect. The five existing public iPad screenshots were verified
there. The build 8 purchase descriptions, review notes and private screenshot
were also saved and verified, and the unsubmitted draft contains version 1.3 (8)
plus the **Ready for Review** purchase.

The English (U.K.) promotional text, description, What's New and app review notes
were saved and verified by clean reload against the four local build 9 files.
Build 9 is selected and Manual release remains selected.

The local English (U.K.) and Spanish purchase descriptions, purchase review notes
and TestFlight instructions also describe build 9. `plus/description-en-GB.txt`
and `plus/description-es-ES.txt` contain the purchase descriptions; `plus/` also
contains the matching review and TestFlight instructions. The English (U.K.) and
Spanish descriptions, purchase review notes, private screenshot and TestFlight
notes were saved and verified by clean reload. The five existing iPad 13-inch
screenshots were also confirmed.

`review-sample.zip` was uploaded as the build 7 App Review attachment. It contains
one CBZ plus import instructions and public-domain credits and remains suitable
for testing the free reader paths.

## Build 9 replacement validation

- Current-page text recognition, selection, copying and system sharing are free.
  PDFs use embedded text when available; image-only pages use on-device
  recognition.
- Plus indexes the current comic page by page, persists partial progress locally,
  supports stop/resume, searches available pages case- and
  diacritic-insensitively in page order, and jumps to results. Saved quotes are
  editable before saving and retain filename/page context for sharing and return.
- Search does not cover the whole library. Search caches and saved quotes are not
  included in iCloud sync, and recognition accuracy is not guaranteed. Saved
  quotes remain readable, shareable and openable after refund; mutations remain
  gated.
- The saved-quotes implementation is complete; all eight isolated tests pass and
  its iOS 15 type-check passes.
- `/tmp/ComicReader-build9-tests3.xcresult` is a valid result bundle recording 55
  unit tests and four UI tests passing: What's New dismissal, free sync without
  purchase, Plus/iCloud separation, and paid Reading List/bookmark persistence
  through refund. The context-menu case was skipped because it needs
  disposable-library setup. Two UI cases initially failed: the quote cell lacked
  its accessibility identifier, which was fixed, and the first cold Files provider remained blank
  for ten seconds. The bundle is therefore not a clean overall pass; earlier
  build 6 context-menu evidence remains separate.
- In `/tmp/ComicReader-build9-ocr-files-verified.xcresult`, the focused Files case
  subsequently passed in 37.257 seconds. The OCR case exercised real recognition,
  free sharing, purchase, indexing, search and jump, quote save/edit, refund and
  relaunch; the exact quote remained available and editing was gated after the
  refund. Its final assertion failed because UIKit replaced the custom share-sheet
  identifier, although accessibility output confirmed the system share sheet and
  expected quote. The helper now accepts the observed system identifiers. The
  corrected test then passed in
  `/tmp/ComicReader-build9-ocr-final-confirmed.xcresult`: one test executed with
  zero failures in 176.454 seconds, with `TEST SUCCEEDED` at 13:07:16
  Europe/Madrid. It confirms real free OCR and system sharing, the actual purchase
  route, indexing, search and page jump, exact quote creation/edit, and retained
  read/share/page-jump access with edit gating after refund and relaunch. Across
  the main and focused runs, 55 unit tests and six distinct UI tests pass.
- The three result bundles, main log, final OCR log and OCR screenshots are copied
  to `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/validation`.
  `release/app-store/validation/quote-after-refund-build9.png` and
  `release/app-store/validation/quote-share-build9.png` were visually inspected
  and preserve the post-refund quote and real system-share evidence.
- The signed 1.3 (9) archive and distribution export passed. The exported IPA
  passed deep strict code-sign verification, has `get-task-allow = false` and
  uses the Production iCloud environment. The fresh local build 9 private
  purchase screenshot is verified in App Store Connect. Two uploads failed with
  Apple 504 responses; the third succeeded at 15:25:21. Build 9 is Validated and
  selected, all app and purchase metadata is verified, and the two-item app/Plus
  submission is Waiting for Review.

## Build 8 processed-draft validation

- The initial integrated Xcode 27 simulator `build-for-testing` passed
  (`/tmp/ComicReader-build8-integrated.log`).
- `Tests/run-cloud-sync-tests.sh` passed after purchase state and entitlement
  gates were removed from the cloud manager and coordinator. The harness retains
  opt-in, account-scoped consent, cancellation, path and integrity coverage; it
  does not validate live iCloud.
- Three selected UI cases logged as passed in 293.278 seconds
  (`/tmp/ComicReader-build8-news-ui.log`): What's New dismissal/upgrade, free
  sync without purchase and the separate Plus screen. `xcodebuild` then hung in
  `_finalizeLogOperation` and required termination, so the invocation has no
  reliable result bundle or overall `TEST EXECUTE SUCCEEDED` record.
- The Reading Lists rerun passed all 5 tests with a valid
  `/tmp/ComicReader-build8-lists.xcresult`. The preceding full-unit run passed
  36 of 37; its only failure was a modification-time equality fixture, fixed by
  normalizing the timestamp to a deterministic whole second.
- The valid `/tmp/ComicReader-build8-final-ui.xcresult` records 6 of 7 selected
  tests passed: one StoreKit lifecycle case, both Image Filter cases, and the
  What's New, free-sync-without-purchase and Plus/iCloud-separation UI cases. The
  paid Reading List/bookmark persistence case failed at reader-toolbar timing
  after its purchase, list, bookmark, filter and refund setup succeeded. Video
  confirmed that the reader opened, so the loading and hittability waits were
  corrected. Visual QA also found and fixed a zero-sized bookmark action
  accessory. No end-to-end paid-flow pass after those changes was recorded: an
  iOS 27 retry stalled in `dyld` before app code and lost the accessibility server
  (`/tmp/ComicReader-build8-paid-verified.log`), and a fresh iOS 26.4 simulator
  failed in `installcoordinationd` before launching the test runner
  (`/tmp/ComicReader-build8-paid-ios26.log`).
- The final signed build 8 archive passed at
  `/tmp/ComicReader-1.3-build8-final.xcarchive` using `iphoneos27.0` with an iOS
  15.0 minimum. Deep strict code-sign verification passed, and the expected
  CloudDocuments entitlement and iCloud container are present. The archive
  includes the bookmark action-accessory fix. Export and upload succeeded at
  11:06 Europe/Madrid, processing reached **Complete**, and App Store Connect
  assigned build UUID `623e6e7a-bf8c-423f-a1ba-97015edeacf1`.
- Build 8 is attached to version 1.3 but has not been submitted. The app metadata
  was saved and read back, and all five public screenshots were verified in App
  Store Connect.
  The revised English (U.K.) and Spanish purchase descriptions, review notes and
  replacement private screenshot were also saved and read back. The purchase is
  **Ready for Review**, and the combined draft shows version 1.3 (8) plus the
  purchase. TestFlight notes were saved and read back. Build 8 was not submitted
  and is superseded by build 9; its binary and saved metadata do not include
  Comic Search & Quotes.

## Build 6 and 7 validation history

- Context-menu source and geometry test: passed in 0.214 seconds
  (`/tmp/comicreader-build6-final-regressions.xcresult`).
- Same-size, same-mtime replacement test: passed in 1.433 seconds after fixing
  the fixture to use a whole-second modification time
  (`/tmp/comicreader-build6-replacement-final.xcresult`).
- Plus portrait and landscape UI test: passed in 34.290 seconds
  (`/tmp/comicreader-build6-plus-ui.xcresult`).
- Build 7's three selected introduction tests logged all assertions as passed
  in 87.996 seconds (`/tmp/comicreader-build7-introduction-ui.log`), but
  `xcodebuild` hung while finalizing results, leaving no usable result bundle or
  overall `TEST EXECUTE SUCCEEDED` record. The focused dismissal/relaunch rerun
  passed in 40.495 seconds with `TEST EXECUTE SUCCEEDED` and a valid result at
  `/tmp/comicreader-build7-final-introduction-ui.xcresult` (log:
  `/tmp/comicreader-build7-final-introduction-ui.log`).
- The build 7 resume test passed in 43.409 seconds with a valid
  `/tmp/comicreader-build7-resume-ui.xcresult`. It verified that the prepared
  saved comic reopened after **Not Now** and after **View Plus**/**Done**,
  including background/foreground. It did not verify an exact resumed page.
- Cover long-press portrait/landscape and delete test: passed in 35.804 seconds
  (`/tmp/comicreader-build6-menu-ui.xcresult`). Only
  `0000-UI-Delete-Regression.cbz` was removed; all nine original samples
  remained byte-identical.
- The Settings and Files test case and suites logged as passed in 38.739 seconds
  at 11:34:26 in `/tmp/comicreader-build6-files-ui.log`. `xcodebuild` then hung
  gathering/finalizing results and was terminated after about six minutes. Its
  `.xcresult` is unusable because `Info.plist` was never finalized, so the
  overall invocation is not recorded as `TEST EXECUTE SUCCEEDED`. The Plus and
  context-menu UI result bundles are valid.
- Portrait visual evidence is good. The landscape XCTest PNG has an orientation
  and cropping artifact, so resized-window landscape visual QA remains
  unverified. The genuine portrait menu image is
  `release/app-store/validation/context-menu-portrait.png`.
- Existing StoreKit tests (0.921 seconds) and import tests (2.438 seconds) passed
  in `/tmp/comicreader-build6-runtime.log`; the 20-test baseline is recorded in
  `/tmp/comicreader-runtime-tests-20260921.log`. Both local cloud-sync harnesses
  passed against temporary fixtures; they do not validate live iCloud.
- Manual reader evidence confirmed a reopen on zero-based page 2. The final
  zero-based page 3 of 4 persisted `currentPage = 3`, `pageCount = 4`, and
  legacy `status = 0`. No reopen was performed after that final state, so the
  evidence does not claim a final reopen on page 3.
- App Review rejected build 7 on 22 September under Guideline 4.10 because its
  submitted Plus benefits charged for iCloud functionality.
- Live free iCloud and Plus purchase propagation across two signed-in devices
  remain unverified because no signed-in, usable device pair is available.

## Version 1.2 validation history

- Xcode 27 simulator `build-for-testing`, build 4: passed.
- Xcode 27 signed Release archive, build 4: passed; code signature verified.
- Bundled archive encryption is explicitly compiled out. The final archive has no removed crypto symbols or strings and declares `ITSAppUsesNonExemptEncryption = NO`.
- Local uploader/WebDAV checks and the reproducible network-path harness: passed.
- Host-native UnRAR harness: passed normal RAR extraction and encrypted-header/entry rejection without output files.
- Runtime verification is incomplete. An earlier build reached the library, settings and Files picker on iPadOS 27, but final-build XCTest and screenshots could not run: simulator launch requests timed out, a fresh iPadOS 27 device stalled on SpringBoard, and a clean iPadOS 26.2 fallback reported DeviceKitError 4002 (no framebuffer provider). A connected, unlocked iPad or a recovered simulator is required to finish.
- App Store Connect login, draft metadata, reviewer notes and reviewer attachment: complete.
- Review contact information was not changed. Apple's submission validation accepted version 1.2 (4) as ready to submit without requesting additional contact information.
- Build 4 upload and Apple processing: passed. Build `b85a7a66-833c-49bf-bb44-e241bad02dbd` has no missing-compliance warning and was submitted as version 1.2 (4).
- New screenshots: deferred at the owner's request; the five current screenshots were submitted.
- App Review submission: completed on 18 September; **Ready for Distribution** on 21 September. Submission ID: `445f78f7-5190-48c3-b2f3-23631145ec76`.

## Version 1.2 artifacts

- Signed archive: `/tmp/ComicReader-1.2-build4.xcarchive`
- Archive log: `/tmp/ComicReader-archive-1.2-build4.log`
- Upload log: `/tmp/ComicReader-upload-1.2-build4.log`
- Simulator build/test-bundle log: `/tmp/ComicReader-sim-build4-tests.log`
- Draft: https://appstoreconnect.apple.com/apps/1597314495/distribution/ios/version/inflight
- Submitted review: https://appstoreconnect.apple.com/apps/1597314495/distribution/reviewsubmissions/details/445f78f7-5190-48c3-b2f3-23631145ec76

See `docs/RegressionReview.md` for the full engineering validation record and known limitations.
