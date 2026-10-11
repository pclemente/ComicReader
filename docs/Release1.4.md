# ComicReader 1.4 (11) App Store submission

Version 1.4 (11) was submitted on 11 October 2026 for iPhone/iPad and Mac.
Both platform submissions are **Waiting for Review**, verified in App Store
Connect. Automatic release after approval is selected; 1.4 is not yet publicly
available. Build 10 was uploaded but was not submitted, and build 11 includes
the verified final Mac import and keyboard fixes.
The 1.3 submission records remain in the existing release documentation.

## One app and one purchase

The app now targets iPhone and iPad (iOS/iPadOS 15+) and Mac Catalyst
(macOS 12+, Intel and Apple silicon). All use
`com.pabloclementeperez.ComicFlow` and the same non-consumable product,
`com.pabloclementeperez.ComicFlow.plus`. The existing €9.99 one-time model
is retained; displayed prices come from StoreKit for the buyer's region.
No subscription or second upgrade was added.

The iOS and macOS 1.4 records contain build 11, saved metadata, required
screenshots and the reviewer sample ZIP. Both are configured for automatic
release after approval. The shared bundle/product configuration enables a
universal purchase; accepted submissions do not establish storefront
availability or prove cross-platform purchase restoration.

## Visible value

- A persistent Get Plus entry becomes Plus for purchasers. Compact screens
  keep Reading Lists, free iCloud, Plus and Settings directly accessible.
- A dismissible 1.4 announcement explains iPhone/iPad/Mac and free sync.
  Dismissal persists, and the banner hides in compact landscape so it does
  not cover the library. It does not repeatedly present a modal paywall.
- The upgrade screen leads with concrete benefits, the current one-time
  price and Restore Purchases. Search/quotes, lists, bookmarks and filters
  have shorter, clearer descriptions.
- Image filters have a free, real preview using the same renderer as the
  reader. Previewing does not change saved reading preferences.
- New Plus Smart Queues group Continue Reading, Unread and Read Again
  across folders. Membership updates from the library's current read state;
  queues are computed rather than saved as duplicate lists. Everyone can
  see counts; opening a queue requires Plus. Custom saved lists remain
  readable after a refund.

Read Again uses the legacy read/normal state, not a new completion metric.
Search indexes, saved quotes, custom lists and bookmarks remain local to
each device. These are not advertised as synchronized data.

## Free sync and reading

Comic files, read/unread state and current page continue to use the existing
`iCloud.com.pabloclementeperez.ComicFlow` CloudDocuments container on all
three platforms. Sync remains free and opt-in, including consent to upload
all library comics to the user's personal iCloud storage. Reading, import,
transfers, current-page text recognition, copying and sharing stay free.

The Catalyst model class is now `ComicCollection` to avoid Carbon's
`Collection` type name. Its explicit SQL table remains `collections`, and
the thumbnail context-menu identifiers retain `Collection:<rowID>`. Existing
library schema/data are preserved.

Mac builds use App Sandbox, user-selected read-only file access for importing,
client/server network access and the same iCloud entitlements. Mac transfer
servers use port 8080. Finder document roles are set for CBZ, CBR and PDF.
The resizable Mac window has a minimum size of 700 × 500. Command-O imports,
Command-R refreshes, and arrow keys move through a comic.

## Packaging

The bundled icon and launch art contained visible stock watermarks. The
candidate uses an original panel-book mark generated from
`Assets/render-app-icon.swift`, with complete iPhone/iPad/Mac icon sizes.
The launch mark preserves its aspect ratio on every screen. The renderer
source is retained so the assets can be reproduced without external artwork.

## Further Plus work worth considering

The previous comparison with Panels and YACReader is in
`MonetizationReview.md`. Smart Queues were selected here because they improve
daily library organization using existing reading state. A dedicated manga
direction mode, continuous webtoon reading and panel navigation could add
more value, but require careful reader/gesture work and are not included or
promised in this candidate. No competitor price was newly verified.

## Validation — 11 October 2026

Xcode 27.0 on macOS 27.0.1 was used for this candidate.

- The final Mac Catalyst unit run passed **61 tests, with 0 failures and 1
  explicitly skipped integration test**. Coverage includes OCR/indexing,
  quotes, page bookmarks, image filters, custom lists and Smart Queues,
  import/library behavior, reader regressions, and five entitlement-ordering
  cases. The machine-readable result is in
  `release/validation/1.4/mac-unit-summary.json`.
- Both CloudSync model and manager host harnesses passed earlier in this
  candidate. Cloud sync code has not changed since those runs.
- Clean iPhone simulator runs passed both focused UI tests. The purchase test
  covered purchase, entitlement recovery after terminating and relaunching the
  app, explicit restore, refund, and continued access to the free iCloud
  screen. The adaptive-layout test covered compact navigation and the free
  image-filter preview. Earlier simulator launch failures were environmental;
  the final clean runs completed successfully.
- The signed Mac app was manually checked for launch, Plus, real Grayscale
  preview, the free iCloud screen and cancellation of upload consent, and
  Command-O's native picker. An isolated Open With import/index check also
  passed. The code signature and sandbox/shared iCloud entitlements validated.
- Live sync between two signed-in devices has not been validated. The passing
  CloudSync harnesses do not prove upload, conflict, offline, or round-trip
  behavior through the production iCloud container.
- Property lists, string tables and `git diff --check` pass.

The hosted Catalyst StoreKit integration attempt cannot establish purchase
correctness. This toolchain links the native macOS StoreKitTest framework
into a Catalyst host: it recorded a test purchase but exposed an empty
`currentEntitlements`, stale transaction details after refund and no refund
update, including with a fresh store instance created after session setup.
That integration test now reports a visible skip on Catalyst; it remains
enabled on iOS. The five deterministic entitlement tests passed, including
old snapshots versus purchase, revocation versus stale positive evidence,
fresh empty snapshots after an account change, and repurchase. Production
entitlements are reconciled from complete verified StoreKit snapshots on
launch, Restore Purchases and foreground activation; grants are not kept
indefinitely to compensate for a broken test harness.

A native macOS StoreKit UI runner was also prototyped so `SKTestSession` could
configure the environment before launching the Catalyst app. Xcode applies one
run destination to the whole scheme: the native macOS destination tried to
build `ComicFlow` as a native Mac app and failed on its iOS launch XIB instead
of producing a Catalyst app. The native target and scheme were removed, and no
production workaround was added. Mac StoreKit lifecycle automation therefore
remains unavailable in this toolchain; the production Mac app was manually
checked as described above.

The focused UI test `testPlusPurchaseRestoreAndRefund` passed purchase,
recovery on a fresh app launch, explicit restore, refund and continued access
to the free iCloud screen. `testAdaptiveNavigationAndFreeFilterPreview` also
passed the new layout and preview checks.

### Reproduce the iPhone checks

Run serially on a working iPhone simulator; replace `PHONE_UDID` below with
its identifier. Use a fresh result-bundle path for each run.

```sh
xcodebuild -project ComicFlow.xcodeproj -scheme ComicFlow \
  -destination 'platform=iOS Simulator,id=PHONE_UDID' \
  -derivedDataPath /tmp/ComicReader-1.4-sim \
  -resultBundlePath /tmp/ComicReader-1.4-iphone-check.xcresult \
  -parallel-testing-enabled NO -jobs 1 \
  -only-testing:ComicReaderUITests/ComicReaderUITests/testPlusPurchaseRestoreAndRefund \
  -only-testing:ComicReaderUITests/ComicReaderUITests/testAdaptiveNavigationAndFreeFilterPreview \
  CODE_SIGNING_ALLOWED=NO test
```

`ComicReader-StoreKit` is an additional scheme with the local StoreKit
configuration for iOS unit integration testing. The normal Mac and app run
schemes do not enable a simulated storefront.

### Final Mac fixes

The native picker now requests a local copy (`asCopy:YES`), preserving the
read-only sandbox entitlement and leaving originals untouched. Open-in-place
selection previously dismissed without a callback. Single- and seven-file
imports now complete, and the file-reference regression passes.

The reader arrow commands now take priority over system focus navigation.
Manual verification confirmed Right displays the next page and Left returns
to the cover. Document geometry and image decoding were correct and unchanged.
See `release/validation/1.4/mac-manual-validation.json`.

### Release status

- iOS submission `2d6748b1-750e-4c6f-8e56-4f67032b3235` is **Waiting for Review**,
  submitted at 14:39 Europe/Madrid on 11 October 2026.
- macOS submission `afed8206-4c44-4df8-a929-873898ba3cf7` is **Waiting for Review**,
  submitted at 14:37 Europe/Madrid on 11 October 2026.
- Both use build 11 with saved metadata, required screenshots and the reviewer
  sample ZIP. Automatic release after approval is selected. The approved Plus
  purchase remains the same €9.99 non-consumable product.
- The final signed archives, export packages and successful upload logs are at
  `/Users/pablocpe/Documents/ComicReader Releases/1.4-build11`. Production iCloud
  entitlements, signatures and matching debug symbols validated on both platforms.
- Build 10 archives remain at
  `/Users/pablocpe/Documents/ComicReader Releases/1.4-build10` as superseded history.
- Submission IDs, package hashes and proof screenshots are recorded in
  `release/app-store/1.4/submission-build11.json` and `submission-proof/` beside it.

### Validation limits

The minimum supported operating systems were not available for runtime testing.
Live two-device iCloud upload, conflict/offline behavior and cross-platform
App Store purchase restoration were not validated. Local model tests,
entitlement inspection and StoreKit test sessions do not prove those live
behaviors. The existing free iCloud implementation is shared across platforms.
