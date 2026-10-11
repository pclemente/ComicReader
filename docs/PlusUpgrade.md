# ComicReader Plus — 1.3 build 9 replacement

## Product and pricing

ComicReader Plus is a **non-consumable, one-time purchase**. Product ID:
`com.pabloclementeperez.ComicFlow.plus` (App Store Connect ID `6814383028`).

The configured base price remains **Spain, €9.99**, with Apple's comparable
prices in other storefronts. The app shows `Product.displayPrice`, never a
hard-coded currency amount. There is no subscription, developer-hosted storage
service or bundled comic content.

Build 9 assigns the purchase four app-specific feature groups:

- **Comic Search & Quotes** builds a persistent page-by-page index for the open
  comic. Search is case- and diacritic-insensitive, lists matches in page order
  and jumps to the selected page. Selected passages can be edited before saving
  and later shared or opened at their source page.
- **Custom Reading Lists** can be created and named; comics from any folder can
  be added and reordered without moving the underlying files.
- **Named Page Bookmarks** can be added, renamed, deleted and opened from the
  reader.
- **Image Filters** unlock Clear Ink (contrast and sharpening), Grayscale and
  Warm Paper presets from the reader toolbar. Filters affect only rendering and
  never modify the comic file; Original is always available to restore normal
  rendering.

Search indexes, saved quotes, Reading Lists and Page Bookmarks are stored on this
device in this release; they are not advertised as cloud-synced. Search covers the
current comic rather than the whole library. Reading, current-page text
recognition, selection, copying, system sharing, folders, local reading progress,
file import, file transfer, local-network upload and WebDAV remain free and unlimited.
iCloud synchronization of comic files, read/unread status and current page is
also free and uses the reader's personal iCloud quota.

## Store behavior

StoreKit 2 verifies current entitlements and transaction updates; no defaults flag
unlocks the purchase. The UI exposes purchase, localized price, Restore Purchases,
pending approval and errors. Revoked/refunded transactions remove Plus access.
Restore calls `AppStore.sync()` only in response to the restore action. Purchase
state does not enable, disable or interrupt iCloud sync. Existing comics and all
free features remain available if Plus is unavailable. Saved quotes remain
available to read, share and open at their source page after a refund or
revocation; creating, editing and deleting quotes requires active Plus access.

Build 8 replaced the build 7 Plus introduction with a dismissible native
**What's New** banner in the library. It appears on the first build 8 launch even
if the earlier Plus introduction was dismissed. Its actions are **Free iCloud
Sync**, **Explore Plus** and an **X** close button. It does not block saved-comic
resume. Build 9 keeps those free-sync and Plus actions and updates the message to
include comic text search and saved quotes.

The Paid Apps agreement, banking status and tax forms were active in App Store
Connect when checked. The purchase has English (U.K.) and Spanish (Spain)
metadata. Family Sharing is not enabled. This first non-consumable was submitted
together with version 1.3 as required by App Store Connect.

## Comic text behavior

The reader's **Comic text and search** screen has This Page, Search and Quotes
views. This Page is free: it uses embedded PDF text when available and otherwise
runs on-device recognition for the current page image. Recognised text is
selectable and can be copied or shared through the system share sheet. A shared
phrase includes the comic filename and one-based page number.

Plus can index the current comic page by page. Indexing starts with the open page,
persists completed pages in a local cache, reports partial progress and can be
stopped and resumed. Available pages remain searchable while indexing continues.
Search is case- and diacritic-insensitive, returns results in page order and opens
the selected page. It does not search every comic in the library.

Saving a quote opens an editor before persistence. Saved quotes are keyed by the
comic's full content fingerprint and stored atomically in Application Support.
They can be opened, edited, deleted, shared with filename/page context, or used to
return to their source page. The text cache and saved quotes stay local and are
not added to iCloud sync. Recognition accuracy depends on language, scan quality
and lettering; neither OCR completeness nor exact transcription is guaranteed.

## Sync behavior

Container: `iCloud.com.pabloclementeperez.ComicFlow` (iCloud Drive / CloudDocuments).

Sync is free for every reader and is opened from the separate iCloud button in
the library toolbar. It starts off. Turning it on explains that all library comic
files and reading progress will be uploaded to the reader's personal iCloud
account and consume storage. A changed iCloud account requires renewed consent.
Turning sync off cancels queued cloud work and leaves existing local/cloud copies
in place.

SHA-256 identifies file contents; filenames do not define identity. Imports use
staged copies, file coordination and integrity checks, and choose another local
filename instead of replacing an unrelated comic. Local metadata is separate
from the original database so the exact final page can be remembered even when
the legacy status is “read”.

Each device owns its reading event file. Newer event timestamps win, with stable
mutation/device tie breakers. Rewinding or marking a comic unread is a valid new
event: the merge never takes the maximum page. An old local library without event
timestamps cannot displace a newer cloud reading event. Events for an open comic
are deferred until the reader closes it; they do not move the visible page.

“Remove from This Device” removes the local file and suppresses automatic download
on that installation. It does not delete the cloud copy or another device's file.
The first release does not expose the engine's delete-everywhere API. iCloud data
can be removed in the system's iCloud storage settings. Reimporting the same comic
locally makes it eligible for syncing on that installation again.

Sync is foreground driven, after imports/library scans, after reading changes and
on Sync Now. Pending downloads retry with a bound; quota, unavailable account and
network failures are visible. Do not describe this as guaranteed instant or
background synchronization. Synced files already downloaded remain usable offline.

## Validation and remaining checks

`Tests/CRCloudSyncModelHarness.swift` exercises deterministic merge/path rules.
`Tests/CRPlusStoreTests.swift` uses StoreKit Test for purchase, restore and refund.
`Resources/ComicReader.storekit` is a local test fixture, not an App Store product
configuration or a production entitlement bypass.

When a usable signed-in device pair is available, complete these follow-up checks:

1. On two signed-in devices, explicitly enable sync without buying Plus.
2. Import a small comic, wait for transfer, and compare all pages on device two.
3. Read forward, close, sync, and reopen on device two at the same page.
4. Finish, rewind and mark unread; verify the latest explicit action wins.
5. Work offline, reconnect, and verify progress reconciles without lost files.
6. Remove locally and confirm the other device's copy remains.
7. Disable sync during transfer, change iCloud account, and verify no automatic
   upload until fresh consent. Check unavailable/full iCloud storage messaging.
8. Without Plus, read text from the current page, select and copy it, and invoke
   system sharing. Verify that Search and Save Quote offer Plus while the free
   page-text actions remain available.
9. Buy and restore Plus, index a comic, stop and resume indexing, search partial
   and complete results with case/accent variants, and jump to matching pages.
   Save, edit, share, open and delete a quote; after refund, verify saved quotes
   remain readable/shareable/openable while mutations offer Plus.
10. Exercise Reading List creation/naming/reordering, Page Bookmark
    add/rename/delete/jump, and all four Image Filters. Confirm Original restores
    normal rendering and no comic bytes change.

Host tests cannot prove Apple's cross-device file propagation. Live iCloud
validation must be recorded separately from simulator/compile results.

### Build 9 candidate status — 22 September 2026

- Build 9 keeps free iCloud sync and adds free current-page text recognition,
  selection, copying and system sharing. Plus adds the persistent current-comic
  search/index and saved-quote workflow as its fourth feature group. No
  whole-library search or text/quote iCloud synchronization is included.
- The saved-quotes implementation is complete; all eight isolated tests pass and
  its iOS 15 type-check passes.
- `/tmp/ComicReader-build9-tests3.xcresult` is valid and records 55 passing unit
  tests plus four passing UI cases: What's New dismissal, free sync without a
  purchase, Plus/iCloud separation and paid Reading List/bookmark persistence
  through refund. One context-menu case was skipped because it requires
  disposable-library setup. The two initial UI failures were a missing quote-cell
  accessibility identifier, which was fixed, and a cold Files provider that remained blank for
  ten seconds. The bundle is therefore not a clean overall pass; earlier build 6
  context-menu evidence remains separate.
- `/tmp/ComicReader-build9-ocr-files-verified.xcresult` records the focused Files
  case passing in 37.257 seconds. Its OCR case completed real recognition, free
  sharing, purchase, indexing, search and page jump, quote save/edit, refund and
  relaunch. The exact quote remained readable and editing was gated after refund.
  The case then failed only because UIKit replaced the custom share-sheet
  identifier; accessibility output confirmed the system share sheet and expected
  quote. The helper was updated for the observed system identifiers. The
  corrected test passed in `/tmp/ComicReader-build9-ocr-final-confirmed.xcresult`:
  one test executed with zero failures in 176.454 seconds and `TEST SUCCEEDED` at
  13:07:16 Europe/Madrid. It confirms real free OCR/system sharing, the actual
  purchase route, index/search/page jump, exact quote creation/edit, and retained
  read/share/page-jump access with edit gating after refund and relaunch. Across
  the main and focused runs, 55 unit tests and six distinct UI tests pass. The
  final result JSON independently reports Passed, 1 total, 1 passed, 0 failed and
  0 skipped on iOS 27.0 (24A434), iPad Pro 11-inch (M5).
- The signed archive at `/tmp/ComicReader-1.3-build9-final.xcarchive` passed
  code-sign verification. It contains version 1.3 (9), targets iOS 15.0 or later
  and was built with the iOS 27 SDK. Its distribution export passed deep strict
  code-sign verification with `get-task-allow = false` and the Production iCloud
  environment. The durable IPA is
  `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/ComicFlow.ipa` with
  SHA-256
  `df6909b10843c0d19db2f059bc970bd690bcd87ac6029b42428b957cb7e330f7`.
- The upload attempt failed at 12:48:44 Europe/Madrid with unexpected HTML and a
  504 gateway timeout while updating `CHECKSUM`. A fresh retry encountered a
  second HTTP 504 at 13:07:21 while completing the asset description and ended
  with exit 70 at 13:13:49 after repeated `CHECKSUM` and analysis-asset failures.
  The third upload succeeded at 15:25:21. Build 9 appeared at 15:27 as
  **Validated** with UUID `82c48917-7a27-4a25-aca5-d9768c8d990f`.
- The English (U.K.) promotional text, description, What's New and app review
  notes were saved and verified by clean reload. Build 9 is selected and Manual
  release remains selected.
- The English (U.K.) and Spanish purchase descriptions, purchase review notes and
  TestFlight instructions are prepared locally for build 9.
  `release/app-store/plus/review-screenshot.png` is now a fresh capture of the
  actual build 9 Plus screen before purchase. Both descriptions, purchase review
  notes and the private screenshot were saved and verified by clean reload; the
  screenshot asset is `1af280f1-0852-4dca-ab26-b48bca576585`. TestFlight notes
  were also saved, and the five existing iPad 13-inch screenshots were confirmed.
- Version 1.3 (9) and ComicReader Plus were submitted together at 15:39 on 22
  September 2026. Both are **Waiting for Review** in submission
  `8528e3cf-59f0-467b-b703-34617ea29110`.
- The three result bundles, main log, final OCR log and OCR screenshots are copied
  to `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/validation`.
  `release/app-store/validation/quote-after-refund-build9.png` and
  `release/app-store/validation/quote-share-build9.png` were visually inspected.
- Build 8 remains processed and attached to the unsubmitted version 1.3 draft.
  Its archive, upload and validation evidence are retained below; it does not
  contain Comic Search & Quotes.

### Build 8 processed-draft history — 22 September 2026

- App Review rejected version 1.3 (7) under Guideline 4.10 because the submitted
  Plus benefits charged for iCloud functionality. Apple's published guideline
  says apps may not monetize built-in operating-system or Apple-provided
  capabilities, including iCloud storage:
  https://developer.apple.com/app-store/review/guidelines/#monetizing-built-in-capabilities
- Build 8 removed every purchase check from iCloud synchronization and presents
  free sync from a separate library-toolbar button. The same non-consumable Plus
  product now covers Reading Lists, Page Bookmarks and Image Filters. It remains
  part of version 1.3. Build 8 was uploaded, finished processing and was attached
  to the app version. The new draft contains version 1.3 (8) and ComicReader Plus
  but has not been submitted, and no App Review reply has been sent.
- `Tests/run-cloud-sync-tests.sh` passed after the entitlement input and gates
  were removed. The manager host contract now starts from explicit opt-in rather
  than purchase state while retaining account consent, cancellation, path and
  integrity checks. This is local host evidence, not live iCloud validation.
- The initial integrated build 8 simulator `build-for-testing` passed
  (`/tmp/ComicReader-build8-integrated.log`). Three selected UI cases logged as
  passed: What's New dismissal/upgrade in 40.696 seconds, free sync without a
  purchase in 226.599 seconds and the separate Plus screen in 25.983 seconds.
  The suites logged as passed in 293.278 seconds
  (`/tmp/ComicReader-build8-news-ui.log`), but `xcodebuild` hung in
  `_finalizeLogOperation` and required termination. That invocation has no
  reliable result bundle or overall `TEST EXECUTE SUCCEEDED` record.
- The focused Reading Lists rerun passed all 5 tests with a valid result bundle
  at `/tmp/ComicReader-build8-lists.xcresult`. An earlier full-unit run passed
  36 of 37 tests; its only failure was a modification-time equality fixture,
  which was normalized to a deterministic whole second before the focused pass.
- `/tmp/ComicReader-build8-final-ui.xcresult` is a valid result bundle recording
  6 of 7 selected tests passed: the StoreKit purchase/restore/refund lifecycle,
  both Image Filter cases, the What's New flow, free sync without purchase and
  Plus/iCloud separation. The paid Reading List/bookmark persistence case failed
  at a reader-toolbar timing assertion after its purchase, list, bookmark, filter
  and refund setup had succeeded. Video showed the reader opened; the test's
  loading and hittability waits were corrected. A later visual check also found
  and fixed a zero-sized bookmark action accessory. No end-to-end pass after
  those fixes was recorded: an iOS 27 retry stalled in `dyld` before app code and
  lost the accessibility server (`/tmp/ComicReader-build8-paid-verified.log`),
  while a fresh iOS 26.4 simulator failed in `installcoordinationd` before the
  test runner launched (`/tmp/ComicReader-build8-paid-ios26.log`).
- The final signed build 8 archive passed at
  `/tmp/ComicReader-1.3-build8-final.xcarchive` using `iphoneos27.0` with an iOS
  15.0 minimum. Deep strict code-sign verification passed, and the expected
  CloudDocuments entitlement and iCloud container are present. The final archive
  includes the bookmark action-accessory fix. App Store export and upload
  succeeded at 11:06 Europe/Madrid (`/tmp/ComicReader-upload-1.3-build8.log`),
  processing reached **Complete**, and App Store Connect assigned build UUID
  `623e6e7a-bf8c-423f-a1ba-97015edeacf1`.
- The five public iPad screenshots remain unchanged. The build 7 private IAP
  screenshot is historical and still ties sync to Plus, so it must not be used
  as build 8 review evidence. The build 8 app description, promotional text,
  release notes and app review notes were saved and read back, and the five
  public screenshots were verified in App Store Connect. The revised English
  (U.K.) and Spanish purchase descriptions and review notes were also saved and
  read back. That build 8 private screenshot is preserved locally at
  `release/app-store/plus/review-screenshot-build8.png` and was uploaded and
  verified as asset `7225cae8-af92-405d-be78-4984cb767a59`. The purchase is **Ready for
  Review** in the new draft, version 1.3 (8) is attached, and the combined draft
  shows two items. TestFlight notes were saved and read back. Build 8 was not
  submitted and is superseded by the build 9 candidate; its uploaded binary and
  saved App Store metadata do not include Comic Search & Quotes.

See `docs/MonetizationReview.md` for the policy and product decision record.

### Build 6 and 7 validation history — 21–22 September 2026

- The final Xcode 27 signed Release archive for **1.3 (6)** passed at
  `/tmp/ComicReader-1.3-build6-final.xcarchive`. It uses `iphoneos27.0`, retains
  an iOS 15.0 minimum, and its signature and entitlements were verified.
- Both local cloud-sync harnesses passed. They cover merge and transfer behavior
  with local fixtures, not Apple iCloud propagation, quotas or multi-device
  delivery.
- The baseline hosted run recorded 20 passing non-StoreKit tests in
  `/tmp/comicreader-runtime-tests-20260921.log`. The focused StoreKit
  purchase/restore/refund lifecycle test passed in 0.921 seconds, and the
  consecutive same-name import regression passed in 2.438 seconds, both in
  `/tmp/comicreader-build6-runtime.log`.
- The app-host context-menu source/geometry regression passed in 0.214 seconds
  (`/tmp/comicreader-build6-final-regressions.xcresult`). The same-size,
  same-mtime replacement reading regression passed in 1.433 seconds
  (`/tmp/comicreader-build6-replacement-final.xcresult`) after its fixture
  timestamp was normalized to a fixed whole second.
- The Plus portrait/landscape UI test passed in 34.290 seconds. The cover
  long-press portrait/landscape and delete test passed in 35.804 seconds; only
  `0000-UI-Delete-Regression.cbz` was removed, and all nine original sample
  comics remained byte-identical. The Settings and Files test case and suites
  logged as passed in 38.739 seconds at 11:34:26 in
  `/tmp/comicreader-build6-files-ui.log`; `xcodebuild` then hung while gathering
  results and was terminated after about six minutes. Its `.xcresult` never
  finalized `Info.plist` and is unusable, so that invocation has no overall
  `TEST EXECUTE SUCCEEDED` result. The Plus and context-menu UI result bundles
  are valid at `/tmp/comicreader-build6-plus-ui.xcresult` and
  `/tmp/comicreader-build6-menu-ui.xcresult`.
- Build 7's three selected Plus introduction tests logged all assertions as
  passed in 87.996 seconds (`/tmp/comicreader-build7-introduction-ui.log`).
  `xcodebuild` then hung during result finalization, so that invocation has no
  usable result bundle or overall `TEST EXECUTE SUCCEEDED` record. A focused
  rerun of the dismissal/relaunch case passed in 40.495 seconds with
  `TEST EXECUTE SUCCEEDED` and a valid result bundle at
  `/tmp/comicreader-build7-final-introduction-ui.xcresult` (log:
  `/tmp/comicreader-build7-final-introduction-ui.log`).
- The build 7 saved-comic resume test passed in 43.409 seconds with a valid
  result bundle at `/tmp/comicreader-build7-resume-ui.xcresult`. It exercised
  **Not Now** and **View Plus** followed by **Done**, including a
  background/foreground interruption, and verified that the prepared saved
  comic reopened. It does not establish an exact resumed page.
- Portrait output was visually checked and looked correct. The landscape XCTest
  PNG has an orientation/cropping artifact, so full visual QA of the resized
  landscape window remains unverified. The genuine portrait context-menu image
  is `release/app-store/validation/context-menu-portrait.png`.
- Manual reader validation reopened at zero-based page 2. The final close on
  page 3 of 4 persisted `currentPage=3`, `pageCount=4` and `legacyStatus=0`; no
  reopen after that final persistence was observed.
- The genuine private build 7 in-app purchase review screenshot at
  `release/app-store/plus/review-screenshot-build7.png` shows the localized €9.99
  price, Restore Purchases and sync off. It was uploaded and saved, then verified
  after reload as asset `98833702-9288-4906-8b47-4742193ce0a5`. The five
  original public App Store screenshots remain unchanged. This private image is
  build 7 history and is not suitable for the revised build 8 Plus benefits.
- The build 6 upload succeeded at 11:18 Europe/Madrid and Apple processing
  reached **Complete**. Build ID: `3140bf50-a330-45b0-a028-6f2e7fab9fca`.
  It was submitted at 14:57 Europe/Madrid under submission
  `41f07f8d-ae7e-4d1b-84a8-8829d8019fcf`; that submission was cancelled on
  21 September and replaced with build 7.
- The signed Release archive for **1.3 (7)** passed at
  `/tmp/ComicReader-1.3-build7-final.xcarchive`. Its App Store Connect upload
  succeeded at 17:42 Europe/Madrid. App Store Connect records the binary as
  **Validated**, uploaded at 17:43, with build ID
  `f18ef6a5-f7c8-443f-a8f0-5ad3b09eaaa0`.
- App Store submission `487b805b-b3fe-42f3-90fe-036c2eaa703a` was sent on
  21 September 2026 at 18:13 Europe/Madrid. App Store Connect confirmed
  **2 Items Submitted**: iOS App 1.3, build 1.3 (7), and the same ComicReader
  Plus in-app purchase. App Review rejected that submission on 22 September
  under Guideline 4.10. The build 7 TestFlight checklist was saved; the internal
  group had zero testers and no invitations were sent.
- Live Plus purchase/restore propagation and free iCloud synchronization across
  two signed-in physical devices remain unverified because no usable signed-in
  pair was available.

Rejected build 7 TestFlight record:
https://appstoreconnect.apple.com/teams/69a6de7e-79b4-47e3-e053-5b8c7c11a4d1/apps/1597314495/testflight/ios/f18ef6a5-f7c8-443f-a8f0-5ad3b09eaaa0

Rejected build 7 submission details:
https://appstoreconnect.apple.com/apps/1597314495/distribution/reviewsubmissions/details/487b805b-b3fe-42f3-90fe-036c2eaa703a

Live two-device validation remains a recorded limitation and follow-up check,
not an approval blocker.

Superseded build 6 archive: `/tmp/ComicReader-1.3-build6-final.xcarchive`.
Build 6 archive log: `/tmp/ComicReader-archive-1.3-build6-final.log`.
Build 6 upload log: `/tmp/ComicReader-upload-1.3-build6.log`.

Rejected build 7 archive: `/tmp/ComicReader-1.3-build7-final.xcarchive`.
Build 7 archive log: `/tmp/ComicReader-archive-1.3-build7-final.log`.
Build 7 upload log: `/tmp/ComicReader-upload-1.3-build7.log`.

Build 8 final archive: `/tmp/ComicReader-1.3-build8-final.xcarchive`.
Build 8 archive log: `/tmp/ComicReader-archive-1.3-build8-final.log`.
Build 8 upload log: `/tmp/ComicReader-upload-1.3-build8.log`.
Build 8 processed UUID: `623e6e7a-bf8c-423f-a1ba-97015edeacf1`.
Build 8 submission artifact: none; the draft was not submitted.

Build 9 integrated result: `/tmp/ComicReader-build9-tests3.xcresult`.
Build 9 focused result: `/tmp/ComicReader-build9-ocr-files-verified.xcresult`.
Build 9 final OCR result: `/tmp/ComicReader-build9-ocr-final-confirmed.xcresult` (passed).
Build 9 final OCR log: `/tmp/ComicReader-build9-ocr-final-confirmed.log`.
Build 9 final archive: `/tmp/ComicReader-1.3-build9-final.xcarchive`.
Build 9 archive log: `/tmp/ComicReader-archive-1.3-build9-final.log`.
Build 9 durable IPA: `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/ComicFlow.ipa`.
Build 9 IPA SHA-256: `df6909b10843c0d19db2f059bc970bd690bcd87ac6029b42428b957cb7e330f7`.
Build 9 upload log: `/tmp/ComicReader-upload-1.3-build9.log` (failed with Apple 504).
Build 9 durable first-failure log: `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-failed.log`.
Build 9 durable retry-failure log: `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-retry-failed.log` (exit 70 at 13:13:49).
Build 9 successful upload log: `/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/upload-succeeded.log`.
Build 9 submission record: `release/app-store/submission-build9.json`.
Build 9 submission ID: `8528e3cf-59f0-467b-b703-34617ea29110` (**Waiting for Review**, two items).
