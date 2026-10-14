# Adaptive reader and iPhone Duo

This change prepares ComicReader for live window resizing, including the transition
between the outer and inner iPhone Duo displays. It uses the current view bounds,
safe areas and display traits, without device-name checks or orientation-based
page sizing. It does not change Plus pricing or free iCloud synchronization.

## Reading behavior

- The selected comic and page survive a viewport change, including a change that
  interrupts a page-turn animation.
- A fitted page remains centered and fully visible inside the usable screen area.
- A zoomed page keeps its magnification relative to fit and its source-page focal
  point. Offsets are clamped when a new aspect ratio makes the old focus unreachable.
- Reader controls follow each safe-area edge independently. Narrow layouts use a
  separate tools row when there is enough height.
- Left, center and right tap zones stay relative to the visible viewport when
  the page is panned or centered with empty space around it.
- Moving to a denser display refreshes the retained page image in place without
  replacing the zoomed view. New thumbnails use a consistent 3× raster density;
  existing cached thumbnails are not reindexed.
- The library reflows its cover columns while retaining a visible comic as its
  scroll anchor. Empty-library content stacks at narrow widths.

## Validation and release status

Validated on 14 October 2026 using Xcode 27.0 and an iPhone 18 Pro simulator on
iOS 27.0 (24A434):

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

The installed toolchain has no iPhone Duo simulator. Apple Developer sign-in is
pending for downloading Xcode 27.1 RC and the matching runtime. Generic viewport
and rotation tests do not establish actual Duo compatibility. This change has
not been uploaded or submitted, and no "first reader" claim is substantiated.

Apple's [Duo preparation guide](https://developer.apple.com/iphone-duo/prepare/)
describes the SDK-dependent layouts; the iOS 27.1 SDK enables the full Duo layout.
Use [Xcode 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)
and the simulator's Device Hub for the final device checks:

1. Import a multi-page comic and open a middle page.
2. Open and close the Duo display repeatedly while fitted, zoomed and panned.
3. Repeat during a page turn, after background/resume, and with reader tools open.
4. Rotate the inner display and test Split View on either side. Check the page,
   controls and library under asymmetric safe areas.
5. Verify the same selected page and usable focus after each transition; inspect
   image sharpness on both displays.
6. Capture genuine outer/inner simulator screenshots only after these checks pass.

Do not publish an optimized-device badge, store screenshot or tested-support claim
based on approximated geometry alone.

## Reproduce the focused tests

Select an available disposable simulator in the destination argument. These tests
import and delete their own fixture comics; do not use a personal library.

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
