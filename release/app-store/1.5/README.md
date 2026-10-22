# ComicReader 1.5 (13)

Work in progress: iPhone Duo support was built with Xcode 27.1 and exercised on an iOS 27.1 iPhone Duo simulator. The final candidate run passed all 55 tests: 51 hosted tests and four UI tests, including geometry checks corrected to use the active scene window and the latest thumbnail-threading fix. Manual Device Hub checks confirmed reopened zoom focus and responsive text tools through partial laptop, partial book and open postures. They do not establish that every orientation transition is automated.

Duo compatibility and opt-in iCloud synchronization remain free. The existing one-time Plus non-consumable and its €9.99 Spain base price are unchanged. No physical iPhone Duo, live two-device iCloud flow or production purchase/restore across platforms has been verified for this candidate.

The last production change confines thumbnail layer apply/release work to the main thread while keeping image decoding in the background. A separate StoreKitTest capture journey passed with no failures and exported five genuine full-inner-display screenshots. All raw captures were reviewed as a contact sheet; the compositor validated five 2853×2007 opaque RGB outputs, and each was inspected individually at high resolution and approved. The ordinary iPhone, iPad and Mac galleries are retained, so no separate outer-display gallery is required.

The Search screenshot uses genuine on-device cover recognition: `watch` returns an indexed result. Recognition of the century-old scan is incomplete because of its source quality; no production OCR code changed for this capture journey.

Store copy has been saved in the iOS and Mac App Store Connect drafts. No builds are selected; release archives, binary upload, build selection and submission remain pending.

See [adaptive reader implementation and validation](../../../docs/AdaptiveReader.md) for the completed evidence, current limitations and release gate.
