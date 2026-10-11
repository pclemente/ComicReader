# ComicReader 1.3 monetization review

## Review outcome

On 22 September 2026, App Review rejected version 1.3 (7) under Guideline
4.10 because ComicReader Plus charged for iCloud synchronization. Apple's
published [Guideline 4.10](https://developer.apple.com/app-store/review/guidelines/#monetizing-built-in-capabilities)
prohibits monetizing built-in operating-system and Apple-provided capabilities,
including iCloud storage. [Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)
allows an in-app purchase to unlock app-specific functionality.

Build 8 and later therefore make iCloud synchronization of comic files, read/unread
status and current page free for everyone. It remains opt-in, uses the reader's
personal iCloud storage and retains account-specific consent and data-integrity
protections. The library exposes it through a separate iCloud toolbar button.

## Plus decision

The existing `com.pabloclementeperez.ComicFlow.plus` non-consumable remains a
one-time €9.99 purchase. Build 9 assigns it four app-specific feature groups:

- **Comic Search & Quotes** builds a persistent page-by-page index for the comic
  being read. Available pages can be searched while indexing continues; work can
  be stopped and resumed. Results are case- and diacritic-insensitive, ordered by
  page and open their source page. Selected passages can be edited before being
  saved as quotes, then shared or opened at their recorded comic page.
- Custom Reading Lists that can be named and reordered across folders without
  moving comic files.
- Named Page Bookmarks that can be added, renamed, deleted and opened.
- Renderer-only Image Filters: Clear Ink, Grayscale and Warm Paper. Clear Ink
  adds contrast and sharpening; no preset modifies comic files, and Original is
  always available to restore normal rendering.

Current-page text recognition, selection, copying and system sharing remain free.
Embedded PDF text is preferred; image-only pages use on-device recognition.
Plus covers the persistent current-comic index, search workflow and saved-quote
records rather than basic recognition or the system share sheet.

Search indexes, saved quotes, Reading Lists and Page Bookmarks remain on this
device in this release and are not represented as iCloud-synced benefits. Search
does not cover the whole library. Recognition may be incomplete or incorrect for
some languages, scans or stylised lettering. Saved quotes remain available to
read, share and open after a refund; Plus gates their creation, editing and
deletion.

## Product comparison and alternatives

The comparison used the official [Panels Premium guide](https://guides.panels.app/premium/what-is-panels-premium)
and [Panels site](https://www.panels.app/). Panels' paid tier covers a wider set
of reading and library features, including panel navigation, additional page
layouts and effects, dynamic backgrounds, incognito reading, text/subject
detection, page filters, external and cloud libraries, OPDS streaming and
advanced themes. Its free tier includes basic, double-page and vertical reading,
basic folders, library search and Files import. Panels offers subscription and
one-time-major-version models; no Panels storefront price was verified or used
to justify ComicReader's price.

The official [YACReader iOS site](https://ios.yacreader.com/) describes library
organization and search, manga and guided/panel reading, double-page, fit and
trim modes, continuous webtoon scrolling, and NAS or desktop streaming. No
verified storefront price was available, so none was used in the decision. This
comparison records the current market feature range; it is not a promise to add
those features to build 9.

A dedicated manga renderer or automatic panel detection could add more value,
but both were deferred because they substantially widen renderer and gesture
regression risk for this replacement build. Paywalling native Live Text was also
rejected because it would create another Guideline 4.10 risk. Build 9 instead
keeps current-page text recognition and sharing free while Plus adds ComicReader's
own persistent current-comic index, search and saved-quote workflow. Panels lists
text and subject detection among its Premium features, which supports the market
comparison but is not treated as an App Review guarantee. An optional tip was
rejected because it would not give purchasers tangible app functionality.

## Release status

Build 8 was uploaded, processed and attached to version 1.3 but was not
submitted. App Store Connect assigned build UUID
`623e6e7a-bf8c-423f-a1ba-97015edeacf1`. Its app metadata, English (U.K.) and
Spanish purchase descriptions, purchase review notes and private screenshot were
saved and read back. The five existing public iPad screenshots were verified.
The build 8 private screenshot is asset
`7225cae8-af92-405d-be78-4984cb767a59`. That draft contained version 1.3 (8) and
the **Ready for Review** purchase.

Build 9 keeps the same app version, product and €9.99 base price and adds the
Comic Search & Quotes implementation described above. Its revised local metadata
is prepared. The saved-quotes implementation's eight isolated tests and iOS 15
type-check pass. Across the main and focused result bundles, 55 unit tests and six
distinct UI tests pass. The final end-to-end OCR case passed one test with zero
failures in 176.454 seconds, covering free recognition and sharing, purchase,
index/search/jump, quote creation/edit, and retained read/share/jump access with
edit gating after refund and relaunch. Its independent result summary reports
Passed, 1 total, 1 passed, 0 failed and 0 skipped on iOS 27.0 (24A434), iPad Pro
13-inch (M5).

The signed 1.3 (9) archive passed code-sign verification. Its distribution export
passed deep strict code-sign verification with `get-task-allow = false` and the
Production iCloud environment. The durable IPA is
`/Users/pablocpe/Documents/ComicReader Releases/1.3-build9/ComicFlow.ipa` with
SHA-256
`df6909b10843c0d19db2f059bc970bd690bcd87ac6029b42428b957cb7e330f7`.
A fresh build 9 private purchase screenshot is prepared locally.

The upload attempt failed at 12:48:44 Europe/Madrid with unexpected HTML and a
504 gateway timeout while updating `CHECKSUM`. A fresh retry encountered another
HTTP 504 at 13:07:21 while completing the asset description, then ended with exit
70 at 13:13:49 after repeated `CHECKSUM` and analysis-asset failures. No build 9
binary was uploaded by those attempts. The third upload succeeded at 15:25:21;
build 9 appeared at 15:27 as **Validated** with UUID
`82c48917-7a27-4a25-aca5-d9768c8d990f`.

All four app metadata fields, both localized purchase descriptions, purchase
review notes and private screenshot were saved and verified by clean reload.
TestFlight notes showed Saved. The five existing iPad screenshots were confirmed, the Spain price
remains €9.99 and Manual release is selected. Version 1.3 (9) and ComicReader Plus
were submitted together at 15:39 on 22 September 2026 and both are **Waiting for
Review** under submission `8528e3cf-59f0-467b-b703-34617ea29110`.
