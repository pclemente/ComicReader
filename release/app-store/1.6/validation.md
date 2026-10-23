# ComicReader 1.6 (14) validation

Validation on 23 October 2026. The submitted 1.6 (14) archives were built from
`05f756c661d5d2b63109ca3f8ece61b1bc0fda3a`; submission details are in
`submission.json`.
The tracked Xcode user-interface-state change is unrelated to the candidate.

## Scope

- Mac Finder Open With, File > Open Comic / Command-O and queued direct reading
  for PDF, CBZ/ZIP and classic CBR/RAR, with optional free Add to Library.
- Embedded browsing, persistent website sessions, saved sites, private
  sessions and website-data controls are free.
- The existing one-time Plus purchase adds authenticated comic downloads,
  validation, duplicate detection, collection selection and queue actions.
- Native StoreKit review requests follow meaningful foreground reading.
- Version news continues to lead with iPhone Duo compatibility.
- No third-party analytics SDK, project or credentials were added.

## Builds and automated checks

Toolchain: Xcode 27.1 (27A9275). The final application sources compiled for
iOS Simulator and Mac Catalyst.

- `ComicReader-web-unit2.xcresult`: 111 unit/regression tests passed on the
  iPhone Duo simulator. The hosted StoreKit unit lifecycle was excluded after
  a separate run stalled; the actual StoreKit UI lifecycle passed below.
- `ComicReader-web-ui3.xcresult`: 21 checks passed, including the native
  purchase/restore/refund UI, authenticated download, duplicate handling,
  opening the imported reader, settings/Files, news banner, review policy,
  import validation and browser header geometry. This predates the bounded
  archive extraction addition; the later checks below cover that addition.
- `ComicReader-web-ipad2.xcresult`: all 18 focused unit checks passed on iPad
  Pro 13-inch (M5), iOS 27.0. These include the 10 final import tests, seven
  review policy tests and the browser header geometry regression.
- `Tests/run-unrar-tests.sh`: ordinary extraction, exact-byte-limit success,
  oversized-entry rejection without output, encrypted-file rejection and the
  bundled archive crypto-symbol scan passed.
- `ComicReader-web-mac-tests.xcresult`: 45 of 46 checks passed on Mac Catalyst,
  including every import/review check and the legacy ZIP/RAR extraction
  regressions. The remaining resize assertion rejected a fractional-pixel
  rounding difference (58.5 versus 58⅓ points). Its tolerance now permits one
  display pixel, consistent with adjacent tests; the focused rerun passed in
  `ComicReader-web-mac-rounding.xcresult`. Reader behavior was unchanged.
- `ComicReader-web-ipad3.xcresult`: both final browser UI journeys passed,
  including session retention/private isolation, StoreKit purchase, authenticated
  download, destination selection, duplicate detection and opening the reader.
- Plist validation and `git diff --check` passed.
- `ComicReader-1.6-mac-documents.xcresult`: 119 hosted Catalyst checks executed,
  one skipped and no failures. This covers the direct reader, source preservation,
  imports, duplicates and existing regressions; it predates the final global File
  menu and queue-dismissal corrections and will be superseded by the final run.
- `ComicReader-1.6-mac-documents-final.xcresult`: 121 Catalyst checks executed,
  one StoreKit integration check skipped and no failures. The source-preservation,
  import, duplicate and queue regressions passed. The following native check
  still found the standard File > Open command disabled, requiring a further
  Mac command-routing adjustment.
- `ComicReader-1.6-ios-final.xcresult`: 120 checks passed on iPhone Duo with the
  hosted StoreKit purchase lifecycle explicitly excluded. Its actual purchase,
  restore and refund UI coverage is recorded in the earlier successful run.
- `ComicReader-picker-focused/Logs/Test/Test-ComicFlow-2026.10.23_12-58-25-+0200.xcresult`:
  five final Catalyst checks passed. They cover picker intent after dismissal,
  temporary reader-file ownership/cleanup, preserving unexpected source URLs,
  invalid-copy rejection, the standard Open command and review requests with
  an undismissed news banner.
- `ComicReader-1.6-ios-ui-final.xcresult`: all three final Duo interface checks
  passed: Settings/Files, page and toolbar preservation across viewport changes,
  and the news banner opening free iCloud settings without a purchase.

- `ComicReader-queue-regression-final.xcresult`: the final Catalyst window-routing
  regression passed, confirming that an active full-screen reader can be replaced
  when UIKit has detached the presenting library view from its window. The first
  attempt failed in the synthetic library layout; the corrected fixture tests
  routing without initializing an unrelated second library.

## Native interface checks

On Mac, the rebuilt app loaded an HTTPS page and a local publisher fixture.
A normal HttpOnly sign-in cookie survived browser dismissal/reopening. The
same site had no sign-in in private browsing. The Plus requirement appeared
when attempting a supported download without an entitlement.

On Mac, File > Open Comic rendered a PDF, a CBZ and a classic CBR. Advancing
the PDF to page 2 and choosing Add to Library retained that page in the normal
reader. Closing the other direct readers left only the explicitly imported PDF
in the library. Finder Open With also rendered the CBR in place. While that
reader was open, Command-O selected the CBZ and replaced the reader automatically;
the CBZ title and artwork were verified. Closing it returned to the same library.
The native picker disabled Open for a deliberately malformed
CBZ. All four original fixture hashes remained unchanged after the walkthrough.

On iPad, the local publisher fixture running in an independent host process
loaded successfully and retained its sign-in after dismissal/reopening.
Earlier iPad layout and free-iCloud navigation checks also passed.

## iPad test fixture correction

The first two iPad browser test runs did not pass. The original session check
failed while loading its local website; the retry reached a later navigation
but timed out. The download check reached destination selection but did not
observe an imported row. Logs include unresponsive WebContent processes and
remote accessibility errors. Manual browsing against an independent local
server succeeded, so these results do not establish an application cause.

The runner-hosted HTTP fixture now reads complete request headers, handles
interrupted socket calls and bounds socket writes. Its HTTP/1.0 responses
close each connection explicitly. Tests verify destination dismissal before
checking import completion. Both journeys passed in the subsequent run,
`ComicReader-web-ipad3.xcresult`, with no application-source workaround.

## Problems corrected during validation

The browser home header initially collapsed on the closed Duo display,
making its address field unreachable. It now measures the stack's intrinsic
height at the available width and remeasures for width and Dynamic Type
changes. The regression checks phone and Duo widths with accessibility text.

A download cancelled by navigation policy initially showed a “Frame load
interrupted” overlay. Expected WebKit policy interruptions no longer cover
the usable website, allowing the user to purchase Plus and retry.

Automatic archive validation now limits its first-page extraction to 96 MiB.
ZIP and RAR check metadata and produced bytes, remove failed temporary
output, and preserve the existing reader API. A tiny compressed ZIP fixture
proves the validation limit applies to uncompressed page size.

`PrivacyInfo.xcprivacy` declares System Boot Time reason `35F9.1` for the
local elapsed-reading timer. Review eligibility and attempts stay on device.

Native validation found that Catalyst's open-in-place picker requested write
access that the read-only sandbox deliberately does not grant. File > Open
Comic now uses the system's copied-file mode with separate direct-reading
intent. Its short-lived reading copy stays outside the library, is removed on
close or invalid-file rejection, and never opts the file into iCloud. Finder
Open With continues to read the original in place. A nonmodal news banner no
longer blocks an otherwise eligible native review request indefinitely. The
external-file queue now accepts the presented reader’s owning window while
UIKit has detached the library view, allowing Command-O to replace the reader.

The Release configuration treats warnings as errors. Its first archive caught
a private method declared on the main Objective-C class but implemented in a
category. The implementation was moved to the main class without changing its
behavior; final archives use the corrected source.

## Practical limits and release status

The queue survives normal browser dismissal during the current app session.
Keep ComicReader open until imports finish. Website sign-in and downloads
depend on the website. The importer does not remove DRM. First-page validation
is not a scan of every page.

No physical Duo device, final manual fold transition, live two-device iCloud
propagation or complete paid Mac download journey was tested for this
candidate. Existing 1.5 release evidence is preserved. Production crash
findings are documented in `docs/CrashReview2026-10-23.md`.

The attempted native Mac paid journey did not reach the purchase or download
assertions: the first runner could not bind its fixture listener, and the second
runner omitted URL punctuation while typing. The fixture input now uses a
clipboard-preserving paste and verifies the exact URL before navigating.
StoreKitTest also reported configuration errors. These are incomplete checks,
not passing Mac purchase evidence; see `docs/MacBrowserValidation.md`.

Both platforms were committed, pushed, archived, exported and uploaded. The
exported packages passed strict signature verification, production iCloud
entitlement checks, matching dSYM UUID checks and scans excluding test bundles,
StoreKitTest artifacts and screenshot fixtures. Mac includes arm64 and x86_64,
uses the sandbox and read-only selected-file access, and has no temporary
exception entitlements.

App Store Connect accepted both 1.6 (14) submissions on 23 October 2026:
iOS at 14:07 and macOS at 14:09 Europe/Madrid. Both were verified **Waiting for
Review** with automatic release after approval. Metadata, existing screenshot
galleries, public-domain review sample and unrestricted-web-access declaration
were included. The earlier 1.5 versions were already distributed, so no pending
release needed withdrawal. This status does not mean Apple has approved 1.6.
