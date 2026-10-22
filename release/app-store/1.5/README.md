# ComicReader 1.5 (13)

ComicReader 1.5 (13) with iPhone Duo support is **Waiting for Review** for iPhone/iPad and Mac. Both submissions are configured to release automatically after approval. The submitted source is commit `d569a4c554c92981b59e7e98cbac83137779f12e`, tree `4f750b362d64282aa2dc668fb47815121894d993`; no source or tests changed afterward.

- iPhone/iPad build `10be3623-55d5-40c6-927a-ae141700f11d`, submission `bc287921-fe82-48a9-aefc-3615ec57e0b7`: **Waiting for Review** at 20:18 CEST on 22 October 2026.
- Mac build `312a19e0-c38a-4c22-9710-2fc55eb5f229`, submission `5a899926-6f95-4aad-84ed-cfa1abd29db5`: **Waiting for Review** at 20:21 CEST on 22 October 2026.

The final run passed all 55 tests: 51 hosted tests and four UI tests, including geometry checks corrected to use the active scene window and the latest thumbnail-threading fix. Manual Device Hub checks confirmed reopened zoom focus and responsive text tools through partial laptop, partial book and open postures. They do not establish that every orientation transition is automated.

Duo compatibility and opt-in iCloud synchronization remain free. The existing one-time Plus non-consumable and its €9.99 Spain base price are unchanged. No physical iPhone Duo, live two-device iCloud flow or production purchase/restore across platforms has been verified for this release.

The last production change confines thumbnail layer apply/release work to the main thread while keeping image decoding in the background. A separate StoreKitTest capture journey passed with no failures and exported five genuine full-inner-display screenshots. All raw captures were reviewed as a contact sheet; the compositor validated five 2853×2007 opaque RGB outputs, and each was inspected individually at high resolution and approved. The ordinary iPhone, iPad and Mac galleries are retained, so no separate outer-display gallery is required.

The Search screenshot uses genuine on-device cover recognition: `watch` returns an indexed result. Recognition of the century-old scan is incomplete because of its source quality; no production OCR code changed for this capture journey.

The signed archives and packages passed validation: iOS arm64, Mac arm64 and x86_64, Production iCloud, matching dSYMs, and no test fixtures. Five new Duo screenshots were uploaded; the ordinary iPhone, iPad and Mac galleries retain five screenshots each.

See [adaptive reader implementation and validation](../../../docs/AdaptiveReader.md) for the completed evidence and remaining limitations. Durable records are in `submission-record.json` and `package-validation.json`.
