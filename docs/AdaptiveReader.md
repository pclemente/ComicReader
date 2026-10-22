# Adaptive reader and iPhone Duo

ComicReader 1.5 adds adaptive support for live window resizing and iPhone Duo.
With the iOS 27.1 SDK, transparent observer views read UIKit's active division and
occlusion reserved regions from `updateConstraints`, where UIKit tracks changes to
those regions. The library and reader then use one continuous, unobstructed pane
inside the safe area. App-owned tool navigation controllers apply the same pane as
an additional safe area. Earlier iOS versions and Mac Catalyst continue to use the
ordinary safe area because the reserved-region API is unavailable there.

The implementation uses reported geometry rather than device-name checks or
orientation-based page sizing. It does not change Plus pricing or free iCloud
synchronization.

For a vertical division, left-to-right layouts use the leading pane and
right-to-left layouts use the opposite pane. A horizontal division uses the top
pane, and ordinary occlusions select the largest remaining clear rectangle.

## Reading behavior

- The selected comic and page survive a viewport change, including a change that
  interrupts a page-turn animation.
- A fitted page remains centered and fully visible inside the usable screen area.
- A zoomed page keeps its magnification relative to fit and its source-page focal
  point. Offsets are clamped when a new aspect ratio makes the old focus unreachable,
  and the source focus is restored if a later viewport makes it reachable again.
  A pan after clamping becomes the new focus, while replacing the page resets it.
- The reader canvas clips neighboring pages at the active pane boundary.
- Reader controls follow each safe-area edge independently. Narrow layouts use a
  separate tools row when there is enough height.
- Comic text, filters, bookmarks, Plus, Reading Lists and iCloud sheets keep their
  app-owned content in one continuous pane while UIKit manages their presentation.
- Left, center and right tap zones stay relative to the visible viewport when
  the page is panned or centered with empty space around it.
- Moving to a denser display refreshes the retained page image in place without
  replacing the zoomed view. New thumbnails use a consistent 3× raster density;
  existing cached thumbnails are not reindexed.
- The library reflows its cover columns while retaining a visible comic as its
  scroll anchor. Empty-library content stacks at narrow widths.

## 22 October 2026 iPhone Duo implementation and validation

The current implementation was built with Xcode 27.1 (27A9275) and the iOS 27.1
simulator runtime (24A94425), then exercised on a dedicated simulator whose device
type is `iPhone-Duo`.

Completed evidence so far:

- `duo-regression-final.xcresult` records **45 passing tests with no failures**:
  18 library/import/state tests, 23 reader tests and four UI tests. This run used
  the iPhone Duo simulator and covers the continuous library viewport, folded
  reader geometry, selected-page and relative-zoom preservation, adaptive controls,
  the 1.5 news banner and free iCloud entry point.
- `duo-clipping-confirmed.xcresult` records a later run in which **42 hosted tests
  passed with no failures**, including the regression that proves adjacent pages
  extend beyond the active reader pane internally but are clipped by its canvas.
- `duo-release-confirmed.xcresult` records **51 passing hosted tests with no
  failures**. Two UI tests covering the 1.5 news banner and its free iCloud entry
  point also passed. The other two UI tests stopped at geometry assertions because
  `app.frame` retained stale 669×951 portrait application geometry while the
  active scene window was 951×669. Those assertions did not establish a product
  failure. The final tests below supersede this run and use the actual scene window.
- `duo-final-55.xcresult` records the final **55 passing tests with no failures**:
  51 hosted tests and all four corrected UI tests. This run includes the latest
  thumbnail change and ended with `TEST SUCCEEDED`.
- Final manual zoom checks are retained as
  `poses/17-final-zoom-before-close.png`, `18-final-zoom-closed.png` and
  `19-final-zoom-reopened.png`. The reopened artwork matches the initial artwork
  exactly outside the pointer-overlay patch, with a whole-image mean RGB absolute
  difference below 0.21 intensity levels. `poses/final-zoom-comparison.json`
  records the comparison rectangle and channel values.
- Final manual text checks moved from open to partial laptop with **Search**
  selected, rotated to partial book with **This Page** selected, then reopened.
  The text view stayed responsive and its content remained inside the active pane;
  `poses/20-final-text-laptop.png` and `21-final-text-book.png` retain the evidence.
- A final smoke check on the thumbnail-fixed build confirmed the compact portrait
  library toolbar keeps Reading Lists, iCloud, Get Plus and Settings visible.
  Backgrounding the reader, closing Duo, resuming from Home and reopening retained
  the same fully fitted comic page. `poses/22-final-portrait-library.png` through
  `25-final-background-reopened.png` retain these checks.

The manual transitions above use the simulator's Device Hub and are separate from
the UI tests. Assigning `XCUIDevice.orientation` does not reproduce every physical
Device Hub posture or display transition, so the automated results do not claim
complete orientation-transition coverage.

The release-confirmed run also exposed off-main-thread thumbnail layer updates.
The current fix leaves image decoding on its background queue, but applies or
releases the UI layer on the main thread only when the thumbnail still has the same
identity and remains attached and visible. It does not use synchronous dispatch.
This was the only production change after the final manual zoom and text captures.

The screenshot helper was also corrected after `XCUIScreen.mainScreen` captured a
black inactive outer display. It chooses a complete screen by normalized aspect,
independent of image orientation, and accepts the full 2852×2006 inner capture with
one-pixel rounding. The compositor applies EXIF transpose and then preserves that
aspect during composition.

The separate `duo-store-capture-complete.xcresult` records a successful StoreKitTest
journey: `testCaptureAppStoreScreenshots` passed with no failures and exported five
genuine full-inner-display attachments for the library, reader, Search, Reading
Lists and free iCloud screens. All raw captures were reviewed together as a contact
sheet. The compositor validated five 2853×2007 opaque RGB outputs, and all five
were inspected individually at high resolution and approved.

The Search capture uses genuine on-device recognition of the cover: searching for
`watch` returned an indexed result. Recognition of this century-old scan is
incomplete, as expected for its source quality; no production OCR code changed for
the capture journey.

The current bundles, logs and posture captures are in
`~/Documents/ComicReader Releases/duo-20261022/validation/`.

## Current limitations and release gate

- The completed Duo work so far is simulator evidence; no physical iPhone Duo has
  been used to verify display density, touch behavior or repeated real-device folds.
- No live two-device iCloud synchronization or production purchase/restore across
  platforms has been verified for this candidate. Duo support and opt-in iCloud
  remain free; the existing one-time Plus purchase and its €9.99 Spain base price
  are unchanged.
- The five genuine full-inner-display App Store captures and composed outputs have
  passed visual QA. The ordinary iPhone, iPad and Mac galleries are retained, so a
  separate outer-display gallery is not required. Engineering pose captures must
  not be used as store screenshots.
- Store copy is saved in the iOS and Mac App Store Connect drafts, with no builds
  selected. Release archives, binary upload, build selection and submission remain
  pending. Do not publish an unsupported "first reader" claim.

## 14 October 2026 installed-tool baseline

This dated section preserves the earlier resize-only evidence and its limitations.
It predates the Xcode 27.1 and iPhone Duo simulator work above.

Adaptive behavior was validated on 14 October 2026 using Xcode 27.0 and an
iPhone 18 Pro simulator on iOS 27.0 (24A434):

- **35 hosted tests passed:** 17 library/import/state tests and 18 reader tests.
  The reader cases cover immediate panning before a resize, frame and bounds
  changes, coalesced expansion/collapse, legal edge clamping, centered fit,
  selected-page preservation, interrupted page animation, retained image refresh
  and tap zones with positive and negative scroll origins. Focal continuity is
  checked within one physical display pixel to allow UIKit's offset quantization.
- **Two UI tests passed** in a separate final run. They cover adaptive library
  controls, the one-time Plus offer and filter preview, scrollable settings, and
  page 2 surviving five portrait/landscape states while reader controls are hidden,
  revealed and used to open the current page's text. All five unobstructed page
  captures were visually checked: page 2 remains fully visible and centered.
- **Release Mac Catalyst arm64 build passed**, without signing. This is a compile
  check, not a Mac runtime, distribution or universal-binary validation.
- The installed simulator's `screenConfig geometry` command was also checked on
  the disposable iPhone 18 Pro. Its primary display rejected a same-orientation
  expansion to `2100x1800@3` because no compatible mode exists. This probe adds no
  live-resize UI coverage; the non-rotation expansion/collapse evidence remains
  the hosted frame/bounds tests.

The hosted results are in `ComicReader-Duo-20261014-confirmed.xcresult`. That
combined invocation also contains two UI startup failures caused by a legacy rating
prompt covering the library. The final UI harness dismisses that prompt through
its normal **Remind Me Later** action; both tests pass with a valid
`ComicReader-Duo-20261014-ui-confirmed.xcresult` and `TEST SUCCEEDED`.
No production code changed between these two runs.

Durable result bundles, logs, result summaries and inspected screenshots are in
`~/Documents/ComicReader Releases/adaptive-reader-20261014/validation/`.
Earlier runs exposed and led to fixes for the focal-point jump, accumulated
whole-point rounding and scrolled-coordinate tap zones. A fresh simulator's initial
installation failure was resolved by restarting it. Xcode also stalled collecting
verbose failure diagnostics; the final runs use `-collect-test-diagnostics never`,
which retains assertions and explicit screenshot attachments.

Duo-specific validation was deferred at that stage: the installed tools had no
iPhone Duo simulator, and Xcode 27.1 RC and its matching runtime were not downloaded.
Hosted frame/bounds tests and iPhone simulator rotation did not establish actual
outer/inner Duo transitions, device-specific safe areas or cross-display density
behavior. The change had not been uploaded or submitted, and no "first reader"
claim was substantiated.

Apple's [Duo preparation guide](https://developer.apple.com/iphone-duo/prepare/)
describes the SDK-dependent layouts; the iOS 27.1 SDK enables the full Duo layout.
The later validation used
[Xcode 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)
and the simulator's Device Hub for these device checks:

1. Import a multi-page comic and open a middle page.
2. Open and close the Duo display repeatedly while fitted, zoomed and panned.
3. Repeat during a page turn, after background/resume, and with reader tools open.
4. Rotate the inner display and test Split View on either side. Check the page,
   controls and library under asymmetric safe areas.
5. Verify the same selected page and usable focus after each transition; inspect
   image sharpness on both displays.
6. Capture genuine full-inner-display simulator screenshots for the Duo gallery
   only after these checks pass; retain the ordinary iPhone, iPad and Mac galleries.

Do not publish an optimized-device badge, store screenshot or tested-support claim
based on approximated geometry alone.

## Reproduce the 14 October focused tests

Select an available disposable simulator in the destination argument. These tests
import and delete their own fixture comics; do not use a personal library.
This reproduces the installed-tool regression path, not Duo-specific validation.

```sh
xcodebuild -project ComicFlow.xcodeproj -scheme ComicFlow \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:ComicReaderTests/ReaderRegressionTests \
  -only-testing:ComicReaderTests/ComicReaderTests \
  -only-testing:ComicReaderUITests/ComicReaderUITests/testReaderRetainsCurrentPageAcrossViewportChanges \
  -only-testing:ComicReaderUITests/ComicReaderUITests/testAdaptiveNavigationAndFreeFilterPreview \
  CODE_SIGNING_ALLOWED=NO test
```
